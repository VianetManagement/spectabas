# Server-Side Conversion Tracking

End-to-end pipeline that captures ad-platform click identifiers, ties them to
user accounts via existing identify + Stripe data, and uploads conversion
events to **Google Ads (Data Manager API)** and **Microsoft Ads (Bulk API)**.

This is the durable, browser-independent measurement path described in the
Kingfisher Ads stakeholder doc, built natively into Spectabas so the customer
site needs zero engineering work.

## The pipeline

```
                 ┌─────────────────┐
   browser ────▶│ tracker click  │ — captures gclid / wbraid / gbraid /
                 │ ID capture     │   msclkid into _sab_click_id session
                 └────────┬───────┘   storage; rides every event POST
                          │
                          ▼
              ┌──────────────────────┐
              │ events table (CH)   │  — stamped with click_id +
              │ ecommerce_events    │    click_id_type at ingest
              └────────┬─────────────┘
                       │
                       ▼
       ┌───────────────────────────────────┐
       │ ConversionDetector (Oban, /15min) │  scans for conversions matching
       │   • Stripe payments               │  per-site ConversionAction rules
       │   • URL pattern (pageview)        │  → resolves first-click within 90d
       │   • Click element                 │  → writes conversions row
       └────────────────┬──────────────────┘
                        ▼
              ┌──────────────────────┐
              │ conversions (PG)    │  pending | skipped_no_click |
              │   - dedup_key       │  skipped_quality | uploaded_google |
              │   - upload_state    │  uploaded_microsoft | failed
              └────────┬─────────────┘
                       │
                       ▼
       ┌────────────────────────────────────┐
       │ ConversionUploader (Oban, hourly)  │  groups by ad platform,
       │   • Google Data Manager API        │  uploads in batches,
       │   • Microsoft Ads Bulk API         │  records match status
       └────────────────────────────────────┘
```

## Data model

### `conversion_actions` (Postgres) — per-site config

| Column | Notes |
|---|---|
| `name` | Friendly label |
| `kind` | `signup` / `listing` / `purchase` / `custom` |
| `detection_type` | `stripe_payment` / `url_pattern` / `click_element` / `custom_event` |
| `detection_config` | JSONB; `{url_pattern: "/welcome*"}` etc |
| `value_strategy` | `count_only` / `from_payment` / `fixed` |
| `attribution_window_days` | 1–90, default 90 |
| `attribution_model` | `first_click` (default) / `last_click` |
| `google_conversion_action_id` | The numeric ID from Google Ads conversion settings |
| `google_account_timezone` | e.g. `America/Chicago`. Match-rate killer if wrong. |
| `microsoft_conversion_name` | The label set in Microsoft Ads conversion goal |
| `max_scraper_score` | Skip uploading if visitor scored ≥ this. Default 40. |

### `conversions` (Postgres) — one row per detected conversion

Resolved-at-detect-time snapshot: `visitor_id`, `email`, `click_id`,
`click_id_type`, `value`, `currency`, `occurred_at`. Plus:

| Column | Notes |
|---|---|
| `detection_source` | `stripe` / `pageview` / `click_element` / `custom_event` / `manual` |
| `source_reference` | `ch_xyz` / `pi_xyz` / event_id / url_path |
| `dedup_key` | Idempotency key. `stripe:ch_abc`, `pageview:visitor_uuid`. |
| `upload_state` | `pending` → `uploading` → `uploaded_*` / `failed` / `skipped_*` |

Unique index on `(site_id, conversion_action_id, dedup_key)` makes detector
re-runs cheap and safe.

## Click-ID tracking

Tracker captures these URL params into `sessionStorage` (rides every event
beacon as `_cid` + `_cidt`, then stamped into `events.click_id` /
`events.click_id_type` at ingest):

| URL param | `click_id_type` | Notes |
|---|---|---|
| `gclid` | `google_ads` | Google web→web standard |
| `wbraid` | `google_ads_wbraid` | Google iOS in-app→web (post-ATT) |
| `gbraid` | `google_ads_gbraid` | Google web→iOS app (post-ATT) |
| `msclkid` | `bing_ads` | Microsoft Ads — auto-tagging must be on |
| `fbclid` | `meta_ads` | Captured but Meta requires Conversions API (not implemented) |

`ClickResolver.resolve/4` walks `events` for a visitor (or all visitors with
the same email) within the attribution window and returns
`{click_id, normalized_type}`. Normalization maps `gclid` → `google`,
`wbraid` → `google_wbraid`, `gbraid` → `google_gbraid`, `msclkid` →
`microsoft`. The uploader uses these to route to the right API + field.

## Detection

Three detectors run from `Workers.ConversionDetector` every 15 minutes:

### 1. Stripe payments → purchase conversions

Scans `ecommerce_events` (CH, populated by the existing Stripe sync) where
`import_source = 'stripe'`. For each new charge, looks up the visitor by the
visitor_id stamped on the row at sync time, resolves first click_id within
90 days, writes a conversion with the actual amount paid.

`dedup_key = stripe:<charge_id>` — re-running the detector never
double-counts.

### 2. URL pattern (pageview)

Scans `events` for pageview rows whose `url_path` matches a configured glob
pattern (`*` → `%` for ClickHouse `LIKE`). One conversion per visitor per
action (idempotent via `dedup_key = pageview:<visitor_id>`).

### 3. Click element

Scans `_click` custom events whose `_id` or `_text` property matches the
configured selector (`#publish-listing` or `text:Publish`). Same one-per-
visitor semantics.

## Upload

`Workers.ConversionUploader` runs hourly per site. Pulls all `pending`
rows, groups by `(conversion_action_id, platform)`, and:

### Google — Data Manager API

```
POST https://datamanager.googleapis.com/v1/events:ingest
{
  "destinations": [{"operatingAccount": {...}, "loginAccount": {...},
                    "productDestinationId": "<conversion action id>"}],
  "encoding": "HEX",
  "events": [{
    "adIdentifiers": {"gclid": "..."},   // or "wbraid" / "gbraid"
    "conversionValue": 49.00,
    "currency": "USD",
    "eventTimestamp": "2026-05-01T15:30:00Z",
    "transactionId": "spectabas:42",
    "eventSource": "WEB"
  }]
}
```

Auth: existing `Spectabas.AdIntegrations.Platforms.GoogleAds` OAuth flow.
Scope is now `adwords` + `datamanager` so existing connections must be
**reconnected** to pick up conversion-upload access.

`wbraid`/`gbraid` go in `adIdentifiers.wbraid` / `adIdentifiers.gbraid`
respectively. Per Google docs the conversion action must have `count: Every`
or these uploads error out.

### Microsoft — Bulk API

CSV upload via the three-step flow (`GetBulkUploadUrl` → `PUT` CSV →
`GetBulkUploadStatus`). MSCLKID is the conversion key. 1000 rows per batch
max. Auto-tagging must be on at the Microsoft Ads account level.

## Idempotency + safety

- **`dedup_key`** prevents double-counting; both detectors and the API
  endpoint can re-run freely.
- **`upload_state`** transitions `pending` → `uploading` → terminal. Mass
  rows get marked `uploading` before the API call so a parallel worker
  can't double-upload.
- **`max_scraper_score`** skips visitors whose score is at or above the
  configured threshold (default 40 = "watching" tier in `ScraperDetector`).
  These rows land in `skipped_quality` and never upload — keeps Smart
  Bidding from learning bot patterns.
- **`SETTINGS max_execution_time`** on every CH query so they can't
  pin CPU.
- **Oban unique** on both workers so a long pass can't pile up retries.

## Backfill

When a Google/Microsoft Ads integration is first connected, the detector
naturally discovers ~90 days of historical conversions on its first run
(it scans back from `max(occurred_at)` of existing rows; first-ever run
defaults to 90 days back). Smart Bidding sees a populated history
immediately — the 2–4 week re-learning window the Kingfisher doc warns
about is compressed because the platform isn't starting from zero.

## What still needs to be configured

The code is built. To go live for a site:

1. **Connect Google Ads + Microsoft Ads** in Settings → Ad Integrations.
   *Existing Google Ads connections need to disconnect and reconnect* to
   grant the new `datamanager` scope.
2. **Get conversion action IDs from Google Ads / Microsoft Ads** (Kingfisher
   creates the actions in the ad UIs and gives you the IDs).
3. **Create conversion actions in Spectabas** at
   `/dashboard/sites/:id/conversions`, mapping each Spectabas detection
   rule to its Google + Microsoft IDs.
4. **Confirm `google_account_timezone`** on each action — wrong timezone
   is the #1 cause of low match rates.
5. **For URL-pattern detection**: confirm the URL patterns. Easiest way
   is to look at existing converters' visit sequences in Spectabas and
   pick the post-conversion landing path.

## Match-rate troubleshooting

Realistic match rate: 80–95% for gclid uploads, lower for wbraid/gbraid.
Common causes of low match rate:

- **Timezone mismatch** between the conversion_at timestamp and the Google
  Ads account TZ. Set `google_account_timezone` correctly.
- **Click expired** (>90 days from the click).
- **MSCLKID auto-tagging off** at the Microsoft Ads account level.
- **wbraid/gbraid conversion action not set to `count: Every`** in Google
  Ads.

## What this does NOT do

- **Meta Conversions API** — not implemented. fbclid is captured at the
  tracker but no uploader. Adding it later is a new module
  (`Spectabas.Conversions.MetaCAPI`) following the same pattern.
- **Hashed PII / Enhanced Conversions for Leads (ECL)** — by design.
  Click-ID-only is lower legal risk; ECL can be a Phase 2 once 60–90 days
  of clean operation is in the books and legal counsel signs off.
- **Modify the customer's site code** — the whole point.
