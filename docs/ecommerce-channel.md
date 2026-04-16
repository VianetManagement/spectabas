# Ecommerce `channel` + `source` dimensions — implementation spec

## TL;DR

Add two optional columns to `ecommerce_events` (ClickHouse): `channel` (distribution platform) and `source` (which UI element led to the purchase). Accept both on `POST /api/v1/sites/:site_id/ecommerce/transactions`. Purely additive — no breaking changes to the API or existing rows.

## Why this is needed

Roommates is the first consumer of Spectabas ecommerce. They decommissioned Matomo and moved revenue tracking entirely to Spectabas. Matomo tracked a custom dimension (`dimension2`) per transaction that carried **two distinct pieces of information** in a single field:

1. **Distribution platform** — whether the purchase came from the website (Stripe) or iOS app (Apple IAP).
2. **Referral source** — which specific UI element led the user to checkout (e.g. dashboard CTA, main menu, an expiration email, the messages paywall).

Matomo conflated both into one `dimension2` string. We're doing it properly with **two columns**:

- **`channel`** — Low-cardinality platform identifier: `"web"` or `"ios_iap"`. Answers "how much revenue comes from web vs iOS?" Stable, closed set — rarely changes.
- **`source`** — The `?ref=` value from the membership page URL, passed through Stripe metadata as `initiated_from`. Answers "which CTA/email/page drives the most conversions?" Open-ended, grows as new referral points are added.

Without these, we can't answer:

- How much revenue did we make on web vs iOS this month?
- Which UI element drives the most subscription purchases?
- Are email-driven conversions higher than dashboard CTAs?
- What's the web-only conversion rate?

Nothing in the existing `ecommerce_events` schema carries this information. `visitor_id` / `session_id` describe the visitor, not the purchase pathway; `items[].category` describes the product type (`"new_subscription"`, `"renewal"`, `"one_time"`), not the channel or referral source.

Both columns use `LowCardinality(String)` in ClickHouse — near-zero storage cost, filter- and group-by-friendly. These are deliberately **generic** fields so other Spectabas customers can adopt them (e.g. `channel: "pos"`, `source: "partner_landing_page"`).

## Client side (already shipped in Roommates)

For context — don't change anything here, just know what's arriving.

`SendToSpectabas.new(...)` in roommates-elixir sends both fields in the JSON body POSTed to `/api/v1/sites/:site_id/ecommerce/transactions`:

```elixir
SendToSpectabas.new(%{
  type: "ecommerce_transaction",
  order_id: "sub_xyz",
  revenue: 9.99,
  email: "user@example.com",
  currency: "USD",
  items: [%{name: "Monthly", price: 9.99, quantity: 1, category: "new_subscription"}],
  channel: "web",
  source: "dashboard.main_cta",
  occurred_at: 1712345678
})
```

Three call sites emit these fields:

| Site | `channel` | `source` |
|---|---|---|
| Stripe `charge.succeeded` (ID Verification) | `"web"` | `initiated_from` (from Stripe metadata, e.g. `"menu"`) |
| Stripe `invoice.payment_succeeded` (subscriptions) | `"web"` | `initiated_from` (e.g. `"dashboard.main_cta"`, `"email.subscription_expired"`) |
| Apple IAP ID Verification (iOS) | `"ios_iap"` | not sent (nil — iOS app doesn't track referral screen) |

### Known `source` values in Roommates

These are the `?ref=` parameters used on `/membership` links across the codebase:

| Source | Where it's linked from |
|---|---|
| `dashboard.main_cta` | Dashboard upgrade button |
| `dashboard.profile_views` | Profile views section CTA |
| `menu` | Main navigation menu |
| `messages` | Messages paywall |
| `profile_bio` | Profile view CTA |
| `edu_banner` | Educational banner |
| `edu_reminder` | Educational reminder |
| `promo_reminder` | Promo reminder |
| `college_reminder` | College promo reminder |
| `email.subscription_expired` | Subscription expired email |
| `email.subscription_expiring` | Subscription expiring email |
| `email.subscription_purchased` | Purchase confirmation email |
| `email.subscription_renewing` | Renewal upcoming email |
| `email.subscription_renewed` | Renewal confirmation email |
| `email.subscription_renew_failed` | Failed renewal email |
| `email.subscription_discount` | Discount offer email |
| `email.subscription_unintended_charge` | Unintended charge email |
| `checkout` | Re-entering checkout after error |

New values may be added over time as new referral points are built. Spectabas should accept any string (no allowlist).

## What to change in Spectabas

All changes are additive. No existing queries or rows need to be touched.

### 1. ClickHouse — add columns to `ecommerce_events`

**File:** `clickhouse/schema.sql` — update the `CREATE TABLE` so fresh installs have both columns:

```sql
CREATE TABLE IF NOT EXISTS spectabas.ecommerce_events
(
    site_id       UInt64,
    visitor_id    String,
    session_id    String,
    order_id      String,
    revenue       Decimal(12, 2) DEFAULT 0,
    subtotal      Decimal(12, 2) DEFAULT 0,
    tax           Decimal(12, 2) DEFAULT 0,
    shipping      Decimal(12, 2) DEFAULT 0,
    discount      Decimal(12, 2) DEFAULT 0,
    currency      LowCardinality(String) DEFAULT 'USD',
    items         String DEFAULT '[]',
    channel       LowCardinality(String) DEFAULT '',
    source        String DEFAULT '',
    timestamp     DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (site_id, timestamp, order_id)
SETTINGS index_granularity = 8192;
```

**File:** `lib/spectabas/clickhouse.ex` — `ensure_schema!/1` already holds additive `ALTER TABLE ADD COLUMN IF NOT EXISTS` migrations for `ecommerce_events` (see `import_source` at line 471). Add two more in the same list, after `import_source`:

```elixir
"ALTER TABLE #{db}.ecommerce_events ADD COLUMN IF NOT EXISTS channel LowCardinality(String) DEFAULT ''",
"ALTER TABLE #{db}.ecommerce_events ADD COLUMN IF NOT EXISTS source String DEFAULT ''",
```

Place them adjacent to the existing ecommerce migrations (around line 471). Idempotent, safe to re-run, auto-applies on app boot.

**Why `LowCardinality(String)` for `channel`:** channels are a small closed set (2–5 values); LC encoding is essentially free and makes `GROUP BY channel` fast. Same choice as `currency` and `import_source`.

**Why plain `String` for `source`:** source values are open-ended (18+ today, growing). `LowCardinality` works fine up to ~10K distinct values but plain `String` is safer for a field that grows with product features. If you prefer LC for query speed, it'll work too — the cardinality is still low enough.

**Why `DEFAULT ''` not `NULL`:** follows the prevailing pattern in this table — all text columns use empty-string defaults, not nullable. Keeps `WHERE channel = 'web'` working without `ifNull`.

### 2. API controller — persist the incoming fields

**File:** `lib/spectabas_web/controllers/api/stats_controller.ex`

In `record_transaction/2` (~line 149), extend the `row` map built before the ClickHouse insert:

```elixir
row = %{
  "site_id" => site.id,
  "visitor_id" => visitor_id,
  "session_id" => params["session_id"] || "",
  "order_id" => order_id,
  "revenue" => parse_amount(params["revenue"]),
  "subtotal" => parse_amount(params["subtotal"]),
  "tax" => parse_amount(params["tax"]),
  "shipping" => parse_amount(params["shipping"]),
  "discount" => parse_amount(params["discount"]),
  "currency" => params["currency"] || site.currency || "USD",
  "items" => Jason.encode!(params["items"] || []),
  "channel" => normalize_short_string(params["channel"]),
  "source" => normalize_short_string(params["source"]),
  "timestamp" => Calendar.strftime(now, "%Y-%m-%d %H:%M:%S")
}
```

Add a private helper alongside `parse_amount/1`:

```elixir
# Normalize a short string field: lowercase, trim, cap length.
# Used for channel and source fields on ecommerce transactions.
# Accepts arbitrary client values — no allowlist — so new values don't
# require a Spectabas deploy. Non-string inputs become empty string.
defp normalize_short_string(nil), do: ""

defp normalize_short_string(value) when is_binary(value) do
  value
  |> String.trim()
  |> String.downcase()
  |> String.slice(0, 64)
end

defp normalize_short_string(_), do: ""
```

64-char cap is a safety rail (all real values are well under that). Lowercasing ensures consistent grouping.

Update the docstring above `record_transaction/2` to document the new fields:

```
"channel": "web",                     (optional, distribution platform: "web", "ios_iap", etc.)
"source": "dashboard.main_cta",       (optional, UI element / referrer that led to purchase)
```

### 3. Postgres — add columns to `ecommerce_orders` (optional / deferred)

**Current state:** `Spectabas.Ecommerce.record_order/2` is defined in `lib/spectabas/ecommerce.ex` but **not currently called anywhere** (verified: `rg 'Ecommerce.record_order'` → 0 hits). The Postgres `ecommerce_orders` table is unused; all reads go through ClickHouse.

**Recommendation:** skip this step for now. Add it only when/if `record_order/2` starts being used. If you want to be thorough for future symmetry:

Create `priv/repo/migrations/<timestamp>_add_channel_and_source_to_ecommerce_orders.exs`:

```elixir
defmodule Spectabas.Repo.Migrations.AddChannelAndSourceToEcommerceOrders do
  use Ecto.Migration

  def change do
    alter table(:ecommerce_orders) do
      add :channel, :string
      add :source, :string
    end
  end
end
```

Then update `@optional_fields` in `lib/spectabas/ecommerce/ecommerce_order.ex:28`:

```elixir
@optional_fields ~w(visitor_id session_id revenue subtotal tax shipping discount currency items channel source)a
```

### 4. Analytics queries — expose as filters / dimensions (deferred)

**Not needed for the Roommates migration itself** — rows will start landing with both fields populated immediately after steps 1 + 2 ship; nothing breaks if nothing queries the columns.

When dashboards need to use these, the changes are confined to `lib/spectabas/analytics.ex`:

- `ecommerce_stats/3` (~line 3321) — accept optional `channel` and `source` filters, add `AND channel = ...` / `AND source = ...` when set.
- `ecommerce_top_products/3` (~line 3351) — same filter options.
- `ecommerce_orders/3` (~line 3381) — expose both in the SELECT so the orders list UI can show them per row.
- Consider `ecommerce_stats_by_channel/3` (one row per channel) and `ecommerce_stats_by_source/3` (one row per source) for dedicated dashboard widgets.

Leave this for a follow-up PR driven by a concrete dashboard requirement.

## Deployment and rollback

**Order of operations:**
1. Merge + deploy this change to Spectabas. On boot, `ensure_schema!` applies the `ALTER TABLE ADD COLUMN IF NOT EXISTS` statements — safe and idempotent. The endpoint starts accepting `channel` and `source` in request bodies; old requests without them continue to work (fields are optional, default to `""`).
2. Roommates ships independently. Their change is already in place — they're sending both fields on every ecommerce transaction. Until step 1 lands, both fields are silently dropped by the Spectabas controller (same as any unknown field today). **No coordination required** between the two deploys.

**Rollback:** trivially safe. Both columns are additive, default-empty, and nothing reads them yet. If you need to revert the controller change, just redeploy the previous commit; the CH columns can stay — unused columns with one value (`''`) are negligible cost.

## Validation

After deploying:

1. **Schema applied:**
   ```sql
   DESCRIBE spectabas.ecommerce_events;
   -- expect `channel` row: LowCardinality(String), default ''
   -- expect `source` row: String, default ''
   ```

2. **Controller accepts and persists:** POST to `/api/v1/sites/<id>/ecommerce/transactions` with both fields:
   ```json
   {"order_id": "test_1", "revenue": 1.00, "channel": "web", "source": "dashboard.main_cta"}
   ```
   Then verify:
   ```sql
   SELECT order_id, channel, source FROM spectabas.ecommerce_events
   WHERE site_id = <id>
   ORDER BY timestamp DESC
   LIMIT 5;
   ```

3. **Backward compat:** POST without either field — row should have `channel = ''`, `source = ''`, response 200.

4. **Normalization:** POST `"channel": "  WEB  ", "source": "  Dashboard.Main_CTA  "` — expect stored values `"web"` and `"dashboard.main_cta"`.

5. **Length cap:** POST `"source": "<70 chars>"` — expect stored value truncated to 64 chars.

6. **Once Roommates is live**, spot-check:
   ```sql
   -- Revenue by platform
   SELECT channel, count() AS n, sum(revenue) AS rev
   FROM spectabas.ecommerce_events
   WHERE site_id = <roommates_site_id>
     AND timestamp >= now() - INTERVAL 7 DAY
   GROUP BY channel
   ORDER BY rev DESC;

   -- Revenue by referral source
   SELECT source, count() AS n, sum(revenue) AS rev
   FROM spectabas.ecommerce_events
   WHERE site_id = <roommates_site_id>
     AND timestamp >= now() - INTERVAL 30 DAY
     AND source != ''
   GROUP BY source
   ORDER BY rev DESC;
   ```

## Testing (ExUnit)

Extend `test/spectabas_web/controllers/api/ecommerce_test.exs`. Add cases for:

- `channel` + `source` present → stored verbatim (after normalization)
- Both absent → stored as `""`, request still 200
- Only `channel` sent (no `source`) → channel stored, source = `""`
- Mixed case / surrounding whitespace → normalized
- Excessive length → truncated to 64 chars
- Non-string values (`42`, `true`, `nil`) → stored as `""`, no crash
- Verify both appear in the ClickHouse row after insert

All tests should work against the existing test ClickHouse setup — no new infrastructure needed.

## Open questions / nice-to-haves (not blocking)

- **Currency for iOS IAP.** Roommates currently hardcodes `"USD"` on the IAP call site. Apple IAP prices are storefront-specific. A future Roommates change could pass the real currency; Spectabas's existing `currency` column already handles it.
- **Backfill.** Pre-migration rows have `channel = ''` and `source = ''`. A one-time backfill from Stripe metadata is possible but not worth doing unless someone asks.
- **iOS source tracking.** Currently Apple IAP transactions arrive with `channel: "ios_iap"` but no `source` (the iOS app doesn't report which screen led to the purchase). If the iOS team adds deep-link tracking, they'd pass a `source` value through the `SendToSpectabas` call — no Spectabas change needed.
