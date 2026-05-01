# Server-Side Ad Conversion Tracking — Setup & Operations Guide

> **Audience**: stakeholders, operators, ad agencies (Kingfisher Ads), and
> customer engineering teams who need to know what was built, who does
> what, and how it works in plain language.
>
> **Companion docs**:
> - `docs/conversions.md` — full technical design (data model, queries, code paths).
> - `/docs` page on the live site — customer-facing API/setup documentation.

---

## TL;DR

Spectabas now uploads conversion events directly to **Google Ads** and
**Microsoft Ads** without depending on the user's browser, ad blockers,
consent banners, or browser privacy software. It does this by:

1. Capturing the click identifier in the URL when a paid ad sends someone
   to the site (`gclid`, `wbraid`, `gbraid`, `msclkid`).
2. Tying that click to the user's account via the existing visitor →
   email linkage and the existing Stripe payment sync.
3. Recording a conversion record in Postgres when one of three events
   happens: a Stripe payment, a pageview matching a configured URL, or a
   click on a configured element.
4. Uploading those records hourly to **Google's Data Manager API** (the
   October 2025 GA replacement for the older Google Ads API) and
   **Microsoft's Bulk Offline Conversions API**.

The system is durable against ad blockers, consent banners, browser
privacy software, and most future privacy changes — because nothing on
the user's browser is required at conversion time. Only the original
ad-click URL needs to land on the site, which always happens.

For **Puppies.com specifically**, this replaces the Kingfisher Ads
"Server-Side Conversion Tracking" plan with a Spectabas-native build —
**zero engineering work required from Puppies.com's team** to go live.

---

## What's in Spectabas now (v6.10.0)

### Storage
- **`conversion_actions`** (Postgres) — per-site config. Each row maps a
  Spectabas-detected event to a Google Ads conversion action ID and a
  Microsoft Ads conversion goal name.
- **`conversions`** (Postgres) — one row per detected conversion.
  Includes the resolved click_id, value, currency, timestamp, upload
  state, and match status. Idempotent via a unique
  `(site_id, action_id, dedup_key)` index — re-running a detector or
  uploader can never double-count.

### Detection (every 15 minutes, per site)

`Workers.ConversionDetector` scans for matches against the configured
conversion actions:

| Detection type | What triggers it | Example |
|---|---|---|
| `stripe_payment` | New row in `ecommerce_events` from the Stripe sync | Membership purchase |
| `url_pattern` | A pageview whose URL matches a glob pattern | `/welcome*` for signup completion |
| `click_element` | A `_click` event on a button/link matching `#id` or `text:Label` | `text:Publish Listing` |
| `custom_event` | A `Spectabas.track('event_name', …)` call from the customer site | Optional, most precise |

Each detector resolves the visitor's first click within the attribution
window (default 90 days) using the existing `events` table in
ClickHouse. If no qualifying click is found, the row is recorded with
state `skipped_no_click` and never uploaded.

### Upload (hourly, per site)

`Workers.ConversionUploader` pulls all `pending` rows for a site, groups
by ad platform + conversion action, and pushes:

| Platform | API | Key | Notes |
|---|---|---|---|
| **Google Ads** | Data Manager API at `/v1/events:ingest` | `gclid` (or `wbraid` / `gbraid` for iOS) | Requires `datamanager` OAuth scope |
| **Microsoft Ads** | Bulk Offline Conversions (CSV) | `msclkid` | Auto-tagging must be on at the account level |

Match results are recorded back on the conversion row. Failed uploads
land in state `failed` with the error captured.

### Tracker

The tracker captures these click identifiers from the URL into
sessionStorage and stamps them on every event:

- `gclid` — Google Ads, web→web
- `wbraid` — Google Ads, iOS in-app→web (post-ATT)
- `gbraid` — Google Ads, web→iOS app (post-ATT)
- `msclkid` — Microsoft Ads
- `fbclid` — Meta (captured but not yet uploaded — Phase 2)
- Plus older click IDs for Pinterest, Reddit, TikTok, Twitter, LinkedIn,
  Snapchat (captured for future expansion).

### Settings UI

`/dashboard/sites/:id/conversions` — full CRUD for conversion actions,
plus per-site summary cards showing pending / uploaded / failed / skipped
counts over the last 7 days.

### Quality gate

Each conversion action has a `max_scraper_score` setting (default `40`
= the scraper detector's "watching" tier). Conversions from visitors at
or above that score are recorded but never uploaded — they land in
`skipped_quality`. This keeps Smart Bidding from learning bot patterns
on sites without email verification.

---

## How it works in plain language

> Walkthrough for a non-engineer stakeholder.

A user clicks a Google ad on their phone in Chrome. Google appends
`?gclid=Cj0KCQiA...` to the URL of the landing page. Spectabas's tracker
sees the URL, pulls out the gclid, and saves it in the user's browser
session.

The user browses around. Every event the tracker sends back to Spectabas
is stamped with the gclid. Spectabas writes those events into ClickHouse.

Three days later, the user signs up. The tracker fires a pageview for
`/welcome` (or whatever URL the signup completes at). Or — for purchases
— the user pays $49 for a Membership. Stripe processes the payment;
Spectabas's existing Stripe sync pulls that payment record into its
`ecommerce_events` table within minutes, including the email address
Stripe knows.

The conversion detector runs every 15 minutes. It sees the new pageview
or Stripe payment, looks up the user's earliest click within the last
90 days (the gclid from three days ago), and writes a conversion record
with the actual amount paid (for purchases) or just a count (for
signups/listings).

The conversion uploader runs hourly. It collects every pending
conversion, groups them by Google Ads or Microsoft Ads, and posts them
to the respective API along with the gclid. Google matches the gclid
back to the original ad click and credits the conversion to whichever
campaign / ad / keyword brought the user to the site three days ago.

Smart Bidding picks up the new conversion data and uses it to decide
which campaigns to spend more on. None of this required any code on the
customer's site, any browser cookie surviving a privacy banner, or any
third-party tag firing.

---

## Setup checklist — who does what

### Spectabas team (us)

- [x] **Done in v6.10.0** — All code shipped. Database tables exist.
      Workers running. Settings UI live. Tracker updated.
- [ ] Validate the Google Data Manager API request format against a real
      Google Ads test account. The exact partial-failure response shape
      may need iteration once we see real traffic.
- [ ] Validate the Microsoft Ads Bulk API CSV column ordering against a
      real Microsoft Ads sandbox. Their docs have changed several times.
- [ ] (Per-customer) After the first week of operation: review match
      rates, surface any low-match cases, adjust conversion-action
      config or quality gate.

### Ad agency (Kingfisher Ads, for Puppies.com)

- [ ] **Create conversion actions in Google Ads** for each of the three
      events Puppies.com wants tracked (Sign-up, Created Listing,
      Membership Purchase). Note each action's numeric ID.
- [ ] **Set the Google Ads account's attribution model** to first-click
      (or whatever the agreed model is) on each conversion action. The
      attribution model is set in Google Ads, not in Spectabas.
- [ ] **For wbraid/gbraid uploads**: set the conversion action's
      `Count` to **`Every`** in Google Ads. Without this, iOS
      conversions will fail to upload.
- [ ] **Create matching offline conversion goals in Microsoft Ads**.
      Note each goal's name.
- [ ] **Verify MSCLKID auto-tagging is enabled** at the Microsoft Ads
      account level. Without this, no msclkid lands in the URL and no
      Microsoft conversion can be tracked.
- [ ] **Hand the IDs/names + the Google Ads account timezone** to the
      Spectabas team or operator. Timezone is the #1 cause of low
      match rates when wrong.
- [ ] During cutover: temporarily switch Smart Bidding strategies to
      Maximize Clicks or Manual CPC to avoid wasted spend during the
      2–4 week re-learning window. Progress back to Maximize Conversion
      Value or Target CPA once Spectabas conversions are flowing
      consistently for at least a week.

### Spectabas operator (or Kingfisher with an operator account)

- [ ] **Connect Google Ads** in Settings → Ad Integrations. *Existing
      Google Ads connections must disconnect and reconnect* to pick up
      the new `datamanager` OAuth scope. Without re-consent, conversion
      uploads will fail with `403 insufficient_scope`.
- [ ] **Connect Microsoft Ads** in Settings → Ad Integrations.
- [ ] **Create conversion actions in Spectabas** at
      `/dashboard/sites/:id/conversions`:
  - Name and kind (`signup` / `listing` / `purchase` / `custom`)
  - Detection type + config
  - Google Ads conversion action ID + account timezone
  - Microsoft Ads conversion goal name
  - Attribution window (90 days default) and model (first_click default)
  - `max_scraper_score` quality gate (40 default)
- [ ] **Confirm URL patterns** for `url_pattern` actions. Look at
      converting visitors' visit sequences in Spectabas to identify the
      post-conversion landing URL. Or ask the customer.
- [ ] **Watch the Conversions page** for the first 48 hours after
      first connecting. Watch the `failed` and `skipped_no_click` counts
      and resolve.

### Customer engineering team

For Puppies.com **nothing is required**. The Stripe integration covers
purchases (the highest-value event); URL patterns cover signups and
listings.

For other customers, the same defaults apply — but if any of these
exist on the site, they're nice-to-have improvements (see Recommended
Improvements below):

- [ ] (Optional) Add `Spectabas.identify(email)` calls on login pages so
      returning users get linked to their click history immediately
      rather than waiting for the next email-verified pageview.
- [ ] (Optional) Add email verification to signup if not already present
      (this is the one place the no-touch design has a hole — see
      Quality gate above).
- [ ] (Optional) Server-side `Spectabas.track('event_name')` calls for
      the most precise event detection (avoiding URL-pattern guessing).

---

## Recommended improvements (in priority order)

### High value, low cost

1. **Email verification on signup** — Without it, every bot signup
   becomes a Smart Bidding signal. v1 mitigates with the bot quality
   gate, but real verification is cleaner. Customer dev: ~1 day.

2. **Identify on login** — `Spectabas.identify(email)` on the customer's
   login page would link returning users to their click history before
   they complete a conversion. Improves attribution for users who
   convert outside the same session as their click. Customer dev:
   ~30 minutes (already documented in `/docs`).

3. **Pre-flight Google Data Manager API request validation** — call the
   API with `validateOnly: true` against a single conversion before
   first real upload. Surfaces config errors (wrong customer ID, missing
   conversion action) immediately. Spectabas dev: ~2 hours.

### Medium value, low cost

4. **Per-action match-rate dashboard** — extend the Conversions page
   summary cards to show match rate per conversion action, not just
   site-wide. Lets the operator spot a single misconfigured action.
   Spectabas dev: ~1 day.

5. **Email allowlist of trusted domains** — exempt some emails from the
   `max_scraper_score` quality gate (e.g. test accounts). Spectabas dev:
   ~half a day.

6. **Conversion replay from `/admin/conversions`** — re-queue a failed
   conversion for upload after fixing config. Right now you'd have to
   `UPDATE` the row directly. Spectabas dev: ~half a day.

### Higher cost, larger payoff

7. **Meta Conversions API uploader** — `fbclid` is captured already.
   New `Spectabas.Conversions.MetaCAPI` module mirroring the Google
   one. Meta matching benefits significantly from hashed email + phone,
   which raises the legal-review bar. Spectabas dev: 1 week + legal
   review.

8. **Enhanced Conversions for Leads (ECL)** for Google Ads — sends
   hashed email/phone alongside the click ID, materially improving
   match rate (~85% → ~95%). Requires per-site legal review. The
   Kingfisher doc flags this as a Phase 2 item. Spectabas dev: ~3 days.

9. **TikTok / Reddit / LinkedIn / Pinterest / Snapchat uploaders** —
   each is a 1–2 day uploader module on top of the existing capture.
   The tracker already grabs all their click IDs.

10. **Direct payments → conversion latency optimization** — currently
    Stripe sync runs every 5 min, then conversion detector runs every
    15 min, then uploader runs hourly. Worst case ~1h20m from payment
    to Smart Bidding seeing it. Could collapse to ~5 min by triggering
    uploader-on-detect. Spectabas dev: ~half a day.

### Strategic / longer-term

11. **Per-site `data_quality` dashboard** — single page showing match
    rate over time, quality-gate skip rate over time, click-id capture
    rate by ad platform, fbclid capture vs upload (post-Meta CAPI).
    Surfaces issues operators can act on. Spectabas dev: ~1 week.

12. **Cross-platform attribution comparison** — when the same click
    converts on Google's reporting and Spectabas's internal attribution,
    show the diff. Useful for legal / dispute / over-credit detection.
    Spectabas dev: ~1 week.

13. **Internal first-click attribution dashboards beyond ad platform
    reporting** — Google's reporting only sees clicks they tracked;
    Spectabas sees the full visitor journey. A dashboard showing the
    full first-click → conversion path including non-paid touches
    (organic, direct, referral) would let Puppies see what *really*
    drives signups vs what Google takes credit for. Spectabas dev:
    ~2 weeks.

---

## Operations

### Health signals to watch (Conversions page on each site)

| Card | Healthy | Warning | Action |
|---|---|---|---|
| Pending | < 50 | > 200 | Uploads are failing — check ad-integration status |
| Uploaded (Google) | Steady ≥ 80% of detections | Drops to 0 | Check OAuth refresh token, re-consent if needed |
| Uploaded (Microsoft) | Steady ≥ 70% of detections | Drops to 0 | Confirm MSCLKID auto-tagging still on |
| Failed | < 5% of total | > 10% of total | Inspect `upload_error` on rows; usually config |

### Common failure modes

- **`skipped_no_click`** — Conversion happened but the visitor has no
  click_id in the last 90d. Either organic/direct traffic (expected,
  not all conversions are from paid) or a click_id wasn't captured
  (rare; usually means the user came in from a non-paid source).
- **`skipped_quality`** — `max_scraper_score` filtered the row. If
  this is a meaningful percentage, either the score threshold is too
  aggressive (raise it) or there's a real bot problem in paid traffic
  (escalate to Kingfisher).
- **`failed`** — API call returned non-success. `upload_error` has
  the message. Most common: `403` (token expired or wrong scope),
  `400` (wrong conversion action ID, wrong timezone in conversion
  timestamp).

### Deployment timezone gotcha

`occurred_at` is stored as UTC in Postgres. Google Ads accepts
ISO-8601 timestamps with offsets, but **the conversion is matched in
the Google Ads account's timezone**. If the configured
`google_account_timezone` doesn't match the actual setting in Google
Ads, conversions land on the wrong day and match rate craters. This is
the #1 cause of low match rates per Google's own troubleshooting docs.

### What to do on the first week of operation

1. **Day 1**: Verify the first conversion uploads. Pull a known recent
   purchase and check the Conversions page that it has state
   `uploaded_google` and `uploaded_microsoft`. Confirm in Google Ads UI
   under "Conversions" that the upload appears (allow up to 12h for
   gclid uploads, up to 72h for wbraid/gbraid).
2. **Day 3**: Compare conversion volume against the prior browser-based
   tracking (or known business volume). Should be ≥ 80% of "real"
   conversion volume — anything less is usually a config issue, not a
   code issue.
3. **Week 1**: Check `failed` count is decreasing as config issues
   shake out. Once it's stable below ~5%, switch Smart Bidding back to
   value-based strategies (Maximize Conversion Value, Target CPA).

---

## What this approach does *not* do (be explicit with stakeholders)

- **It does not provide on-site analytics.** Tools like GA4 still need
  browser-based tracking and will continue to be affected by privacy
  software. This system is purpose-built for ad platform conversion
  measurement, not site behavior analysis.
- **It does not reach users who arrived via channels other than tracked
  paid ads.** Organic search, direct, referral, and email traffic do
  not have click identifiers and are not part of this system.
  Conversion attribution for those channels remains unchanged in
  Spectabas's existing dashboards.
- **It does not bypass any legal consent requirement.** The system is
  designed around minimal, click-identifier-only data sharing that is
  generally considered low-risk from a privacy perspective. Compliance
  posture should be confirmed by the customer's legal counsel.
- **It does not entirely eliminate measurement loss.** A small
  percentage of users will still be missed due to natural limits of
  click-identifier attribution (clicks expiring after 90 days, users
  converting outside the attribution window, etc.). Expected match
  rates are 80–95%.

---

## Where to find more detail

- **Technical design** (data model, queries, code paths):
  `docs/conversions.md`
- **Code**: `lib/spectabas/conversions/`, `lib/spectabas/workers/conversion_*.ex`
- **UI**: `lib/spectabas_web/live/dashboard/conversions_live.ex`
- **Tracker click capture**: `assets/js/spectabas.js` (source) +
  `priv/static/s.js` (production minified)
- **Google API client**: `lib/spectabas/conversions/google_data_manager.ex`
- **Microsoft API client**: `lib/spectabas/conversions/microsoft_ads.ex`
- **Customer-facing /docs page**: `lib/spectabas_web/live/docs_live.ex`
  (Server-Side Conversions section, added in this release)

---

*This document was generated when the v6.10.0 release shipped. Update
as the system evolves.*
