# Spectabas — Developer Guide

## What is this?

Spectabas is a multi-tenant, privacy-first web analytics SaaS built with Elixir/Phoenix. Tracks pageviews via a JS tracker served from customer analytics subdomains (e.g. `b.dogbreederlicensing.org`).

## Tech Stack

- **Elixir 1.18 / Phoenix 1.8** — LiveView, scope-based auth (`current_scope`, not `current_user`)
- **PostgreSQL** — users, sites, sessions, visitors, audit logs
- **ClickHouse** — event storage and analytics queries
- **Chart.js** — vendored UMD build (no CDN)
- **wax_** — WebAuthn/passkey 2FA (FIDO2, platform authenticators)
- **tzdata** — required for site timezone support
- **Render** — Docker deployment, Ohio region

## Architecture

### Data Flow
1. Site loads `/assets/v1.js` from analytics subdomain
2. Beacon to `/c/e?s=<public_key>` (obfuscated)
3. CollectController validates, resolves site by public key
4. Ingest enriches (IP geo, UA, session, intent, visitor dedup)
5. IngestBuffer batches (500), async flushes to ClickHouse (Finch pool, 10 connections)
   - **Fast path**: custom/duration events skip GeoIP, session resolution, UTMs, intent classification (inherit from pageview)
   - **Full path**: pageviews and ecommerce events get complete enrichment
6. Dashboard LiveViews query ClickHouse directly

### IP Enrichment: DB-IP (geo/ASN) → MaxMind (timezone/EU) → ASN Blocklists (datacenter/VPN/TOR) → UAInspector (browser/OS/bot) → Intent Classifier

### Key Endpoints
`/assets/v1.js` (tracker), `/c/e` (events POST), `/c/p` (noscript pixel), `/c/i` (identify), `/c/x` (cross-domain), `/c/o` (opt-out), `/api/v1/sites/:id/identify` (server-side identify)

### ClickHouse Schema
- Auto-created on startup (`ensure_schema!`). Writer needs INSERT + SELECT + ALTER UPDATE.
- Column naming: `ip_country` not `country`, `duration_s` not `duration`, `referrer_url` not `referrer`
- Bloom filter skip indexes on: session_id, visitor_id, ip_country, browser, referrer_domain, click_id

## Development

```bash
mix deps.get && mix ecto.setup && mix phx.server
```
Tests: `mix test` (609 tests, no ClickHouse needed) | Format: `mix format` | Compile: `mix compile --warnings-as-errors`

## Deployment

Push to `main` → auto-deploy on Render (~2-3 min Docker build).

### Services (Ohio)
- Web: `srv-d72usa4r85hc73efqgpg` | ClickHouse: `srv-d72use0gjchc73as2rl0` (private) | PG: `dpg-d72us1nkijhs73d77grg-a`

### Environment Variables
`DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` (`www.spectabas.com`), `CLICKHOUSE_URL` (`http://spectabas-clickhouse:10000`), `CLICKHOUSE_DB`, `CLICKHOUSE_WRITER_USER/PASSWORD`, `CLICKHOUSE_READER_USER/PASSWORD`, `RENDER_API_KEY`, `RENDER_SERVICE_ID`, `RESEND_API_KEY`, `MAXMIND_LICENSE_KEY` (optional), `APPSIGNAL_PUSH_API_KEY`, `IPAPI_API_KEY` (VPN MMDB), `SLACK_WEBHOOK_URL`, `UTILITY_TOKEN`, `HELP_AI_API_KEY` (Anthropic key for dashboard help chatbot), `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT` (Cloudflare R2 for GeoIP + exports)

### Adding a tracked site
1. Create in Admin > Sites (domain = analytics subdomain) — auto-registers on Render
2. DNS CNAME: `b.example.com` → `www.spectabas.com` (gray cloud if Cloudflare)
3. Install snippet from site settings. Parent domain auto-allowed for origin checks.

### Diagnostic endpoints
`/health`, `/health/diag`, `/health/dashboard-test`, `/health/audit-test`, `/health/backfill-geo`, `/health/ecom-diag` (supports `action=sync&start=YYYY-MM-DD&bg=1`), `/health/fix-ch-schema` (uses admin user for DDL), `/admin/ingest`, `/admin/api-logs`

### GeoIP Updates
DB-IP + MaxMind + ipapi.is VPN refresh via Oban cron (1st/15th monthly, 06:00 UTC). All MMDB files synced to R2 after download. On boot, pulled from R2 to `/tmp/spectabas_geoip/` (ephemeral). Falls back to Docker-baked priv/ files. Trigger manual refresh: `/oban-admin?token=...&action=refresh_geoip`.

## Dashboard (39 pages, 7 categories)

- **Overview**: Dashboard, Insights (8 anomaly types + AI analysis), Journeys, Realtime
- **Behavior**: Pages (device split, row evolution sparklines), Entry/Exit, Page Transitions, Site Search, Outbound Links, Downloads, Events (ARRAY JOIN property breakdown), Performance (RUM/CWV)
- **Acquisition**: Acquisition (channels + sources + UTM tabs), Campaigns, Search Keywords (GSC + Bing)
- **Audience**: Geography, Visitor Map, Devices, Network, Bot Traffic, Scrapers, Visitor Log, Cohort Retention, Churn Risk
- **Conversions**: Goals (pageview, custom event, click element — each clickable for detail page), Click Elements (registry with naming, filtering, goal cross-refs), Funnels (with revenue + abandoned export), Ecommerce, Revenue Attribution (ROAS, click ID), Revenue Cohorts, Buyer Patterns, MRR & Subscriptions
- **Ad Effectiveness**: Visitor Quality, Time to Convert, Ad Visitor Paths, Ad-to-Churn, Organic Lift
- **Tools**: Reports, Email Reports (daily/weekly/monthly + AI weekly), Exports, Settings (4 tabs)
- Category landing pages at `/sites/:id/c/:category`. Sidebar anomaly badges from `AnomalyDetector`.

## Multi-Tenancy

Accounts are tenant boundaries. Sites/Users belong via `account_id`. ClickHouse keyed by `site_id`.

| Role | Scope | Access |
|------|-------|--------|
| platform_admin | Global (account_id=NULL) | All accounts/sites/users |
| superadmin | Account | Own account's sites/users, can invite any role |
| admin | Account | Own account's sites only |
| analyst | Account+Site | Explicit per-site permission, can create goals/funnels |
| viewer | Account+Site | Read-only on permitted sites |

Routes: `/platform/*` (platform_admin), `/admin/*` (superadmin+), `/dashboard/*` (all authed, scoped by `can_access_site?`)

## Authentication

- **MFA**: TOTP + WebAuthn/Passkeys. Account-level `require_mfa` toggle. `Require2FA` plug checks `totp_verified_at` (12h validity).
- **SOC2**: 12-char passwords (letter+number), 5-attempt lockout (15min, Hammer ETS), 30-min idle timeout (JS tracking, 28-min warning), session management (IP/UA/last_active on `users_tokens`), audit logging.
- **wax_ config**: Requires `origin` in `config.exs` and `test.exs` — tests fail without it.
- **API keys**: Scopes (`read:stats`, `read:visitors`, `write:events`, `write:identify`, `admin:sites`), site restrictions, optional expiry. All calls logged (30-day retention, `/admin/api-logs`).

## Security (4 audits completed: v0.8.0, v1.6.0, v2.6.0, v4.8.0)

30 findings fixed across audits. Key ongoing rules enforced:
- All ClickHouse params via `ClickHouse.param/1` (SQL injection prevention)
- Segment ownership scoped by user_id + site_id (IDOR prevention)
- Origin validation on all `/c/*` endpoints including `/c/i` and `/c/x`
- Field length limits on `_fp` (256), `_cid` (256), `_cidt` (32)
- Click ID validation: 5-256 chars, alphanumeric + `-_=.`
- LIKE patterns escape `%` and `_` wildcards
- IP priority: `X-Spectabas-Real-IP` > `X-Forwarded-For` > `CF-Connecting-IP` > `conn.remote_ip`

## Important Patterns

### ClickHouse Gotchas
- **JSON types**: All values returned as strings. Use `to_num/1`/`to_float/1` before arithmetic.
- **CTEs with JOINs time out** on large tables. Use flat GROUP BY. Revenue attribution uses parallel flat queries.
- **Alias collisions**: Never alias to same name as source column. `sum(clicks) AS clicks` → nested aggregation error. `toString(date) AS date` → type conflict. With `FINAL`, may silently return 0 rows. Fix: distinct aliases (`total_clicks`, `bucket`).
- **argMinIf/argMaxIf**: Return `''` not NULL when no match. Wrap: `ifNull(nullIf(argMinIf(...), ''), 'Direct')`.
- **LEFT JOIN + non-Nullable**: Returns default (0) not NULL on miss. Never use `avg()` — use `sum(col) / greatest(countDistinct(id), 1)`.
- **Schema migrations**: `CREATE TABLE IF NOT EXISTS` won't add columns. Use `ALTER TABLE ADD COLUMN IF NOT EXISTS`.
- **OPTIMIZE DEDUPLICATE BY**: Must include ALL ORDER BY columns.
- **quantileIf**: Returns `nan` on no matches — `parse_rows` sanitizes to `null`.
- **Mutations**: Max 1000 pending; chunk IN clauses at 500 IPs.

### Query Rules
- **ALL analytics queries MUST include `ip_is_bot = 0`** and filter to pageview events. Exceptions: network_stats (bot %), realtime, visitor detail, RUM.
- **Bounce rate**: `countIf(pv = 1)` only. No duration/custom event factors.
- **Bot vs datacenter**: `ip_is_bot` = UA detection only. `ip_is_datacenter` does NOT mean bot (VPN/corporate proxy users are real).
- **Ad spend queries**: Always `FROM ad_spend FINAL` for dedup.

### Rollup Tables (AggregatingMergeTree)
6 tables (`daily_rollup`, `daily_page_rollup`, `daily_source_rollup`, `daily_geo_rollup`, `daily_device_rollup`, `daily_event_rollup`) populated by `DailyRollup` worker (01:30 UTC cron + one-shot backfill). Use `countIfMerge`/`uniqExactIfMerge` (keep `-If` in Merge name). Rollup query pattern: prior days from rollup, today+yesterday from raw events as states, UNION ALL into outer merge. Segmented queries fall back to raw events. Re-runs DELETE first (`mutations_sync=2`) because `countIfState` sums on merge. Never use old `daily_stats` SummingMergeTree — inflates uniqExact.

### Fast Paths
- `timeseries_fast/4` for >= 30 days (rollup + raw today/yesterday). `timeseries/4` for < 30 days (hourly).
- Both use `uniqExactIf(visitor_id, event_type='pageview')` matching `overview_stats` exactly.

### Dashboard Architecture
- **Async progressive loading**: Mount loads critical stats synchronously, then `handle_info(:load_deferred)` spawns unlinked tasks. Each sends `{:deferred_result, key, value, cache_key}`. `cache_key` guards stale results on range switch.
- **Slow query log**: `timed/4` logs queries >500ms at notice level: `[Dashboard:slow] <name> site=<id> days=<n> took=<ms>ms`.
- **Chart.js initial data**: Use `data-chart` attribute (not `push_event` during mount — race condition). `chart_key` suffix on DOM id for reload. `phx-update="ignore"` on canvas.

### Tracker Behavior
- **GDPR default**: `data-gdpr="off"` (cookie-based). `"on"` = fingerprint-only.
- **Visitor dedup**: GDPR-off: new cookie = new visitor, no fingerprint merging. Fingerprint dedup only in GDPR-on via `Visitors.find_by_fingerprint/2`.
- **External identity cookie**: `data-xid-cookie` attr → reads customer cookie → sends as `_xid`. Merges visitors when `_sab` changes but `_xid` matches.
- **Auto-click tracking**: Captures clicks on `<button>`, `<a>` (internal), `<input[type=submit]>`, `[role=button]`. Sends `_click` custom event with `_tag`, `_text`, `_id`, `_classes`, `_href` properties. 500ms debounce. Skips outbound links (already tracked as `_outbound`). Powers click element goals.
- **Click ID capture**: gclid/msclkid/fbclid from URL → sessionStorage → `_cid`/`_cidt`. Invalid silently dropped.
- **Pageview rate limiting**: 5s min interval per pathname (sessionStorage). Query-string changes ignored.
- **SPA tracking**: Only pathname changes trigger pageviews.
- **RUM**: `_rum` (nav timing) + `_cwv` (Core Web Vitals). Uses `nav.startTime` (always 0), NOT `nav.navigationStart` (deprecated).

### Proxy & Origin
- **Ad blocker evasion**: `data-proxy` for reverse proxy. Proxy plug MUST go in endpoint.ex before Plug.Parsers. Cloudflare Bot Fight Mode needs WAF skip for `/t/*`.
- **Origin validation**: Auto-allows parent domain + any subdomain. Cross-domain list for separate domains.
- **Tracking subdomain plug**: Blocks UI routes on analytics subdomains — only `/c/*`, `/assets/v1.js`, `/health`.

### Integrations
- **Encrypted storage**: OAuth tokens via `Spectabas.AdIntegrations.Vault` (AES-256-GCM). Credentials in `sites.ad_credentials_encrypted`.
- **HTTP retry**: All calls via `Spectabas.AdIntegrations.HTTP` (3 retries, exponential backoff).
- **Sync lock**: Postgres advisory locks (`pg_try_advisory_lock`) prevent concurrent duplicate inserts across instances. Local `persistent_term` for fast check.
- **Smart sync**: Payment providers fetch today; if last sync >6h ago, include yesterday. Backfill checks CH first.
- **Configurable frequency**: `extra["sync_frequency_minutes"]`. Default 15min (payments), 6h (ads). Oban cron every 5min, `should_sync?/1` gates.
- **mark_error**: Keeps `status: "active"` (cron retries). Only stores message + increments count.
- **IDOR protection**: `authorize_integration!/2` before any operation.
- **Credential masking**: Show `****...last4` in forms, never re-display.
- **Auto-repair**: Settings `mount` calls `auto_repair_integrations/1` for orphaned records.
- **Stripe**: PaymentIntents API (pi_*), NOT Charges (ch_*). When Stripe integration exists, filter `import_source = 'stripe'` only.
- **Braintree pagination**: Two-step: `advanced_search_ids` for all IDs, then `advanced_search` with `<ids>` in 50-item chunks.
- **import_source**: `"stripe"`, `"braintree"`, `""` (API). Clear Data scoped to matching source.
- **Campaign ID resolution**: Match `utm_campaign` to ad spend by both `campaign_name` AND `campaign_id`.
- **MRR**: `sum(unit_amount * quantity)`, apply discount, normalize interval (weekly*4.33, monthly*1, quarterly/3, annual/12).

### Scraper Detection
Weighted-signal scoring (15 signals, cap 100). Tiers: watching (40-69), suspicious (70-84), certain (85+). Uses `uniqIf(url_path)` not `countIf`. VPN providers suppress `datacenter_asn` and `spoofed_mobile_ua` signals — `known_vpn_provider?` trims whitespace, `is_vpn` checks `in [true, 1, "1"]`. `ScraperDetector` is pure/stateless. Webhooks fire at 40+ via `ScraperWebhookScan` (15min Oban), payload includes `sab_cookie`. ASN management: `ASNDiscovery` weekly (Sunday 04:00 UTC), `ASNBlocklist` ETS (~900 ASNs). **IMPORTANT**: Scraper queries MUST use `argMaxIf(field, timestamp, event_type='pageview')` not `argMax` — lightweight ingest path leaves enrichment fields empty on custom/duration events. Manual "Mark as Scraper" button on visitor profiles sets score 100 + sends webhook + sets `scraper_manual_flag = true`. Manually-flagged visitors are excluded from the 15-min downgrade scan in `check_downgrades` so the sticky manual flag survives even when their automatic score drops below the watching threshold. The "Marked as Scraper" badge on the visitor profile checks `scraper_manual_flag OR scraper_webhook_score == 100`.

### UI Patterns
- All pages use `<.dashboard_layout>` from SidebarComponent
- Flash: unified toast in SidebarComponent. Do NOT add inline flash rendering in pages.
- Buttons: `rounded-lg`. Primary: `bg-indigo-600 hover:bg-indigo-700`. 
- Category landing pages: single `CategoryLive` with all 39 descriptions.

### Misc
- **Timezone**: `tzdata` required. Dashboard dates via `dates_to_utc_range/3` (site TZ). Rolling periods UTC-relative. CH timestamps via `tz_sql/1` helper.
- **Spam filter**: `SpamFilter` module + `SpamDetector` Oban worker. Admin at `/admin/spam-filter`.
- **Site search params**: Per-site `search_query_params` in Settings > Content. Defaults: `q`, `query`, `search`, `s`, `keyword`.
- **Geolix maps**: Use both atom and string keys — `Map.get(names, "en") || Map.get(names, :en)`
- **ObanRepo**: Dedicated 25-conn pool (web pool = 10). Same DB, prevents sync starving web.
- **Backpressure**: 503 at buffer 5,000. Health "overloaded" at buffer 8,000 or Oban queue 500k.
- **AI**: Per-site config in `ai_config_encrypted` (provider, api_key, model, `auto_generate`, `email_enabled`). `AI.Completion.generate/4` abstracts providers and accepts `max_tokens:` (default 2048; insights pass 8192). `InsightsCache` persists last analysis. Weekly cron `AIWeeklyEmail` runs Mondays 9am UTC and only touches sites where `auto_generate` is on; emails to email-report subscribers only when `email_enabled` is on. Toggles live at Settings → Content → AI Analysis. Platform-level help chatbot via `HELP_AI_API_KEY` (Anthropic Haiku) — `AI.HelpChat` module, `ChatComponent` LiveComponent in dashboard_layout.
- **fix-ch-schema**: Uses `execute_admin` for DDL (writer may lack ALTER privileges).
- **R2 storage**: `Spectabas.R2` module — S3v4 signing, upload/download/presigned URLs. Used for GeoIP MMDB files and data exports. Env: `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`.
- **Deterministic sessions**: Session IDs derived from `hash(site_id, visitor_id, 30-min-bucket)` — no shared state needed across instances. Postgres upsert on conflict.
- **Oban timeouts**: All 29 workers have `timeout/1` callbacks (60s emails, 120s exports, 300s API syncs, 600s ClickHouse maintenance).
- **Death Star spinner**: `<.death_star_spinner class="w-4 h-4" />` — custom SVG component, globally available.
- **Heroicons setup**: `assets/css/app.css` activates the per-icon CSS via `@plugin "../vendor/heroicons"` AND adds a `mask-size: contain` rule for any `[class*="hero-"]` element. Both are required: without `@plugin` the per-icon classes are never generated and every `<.icon name="hero-..." />` renders blank; without `mask-size: contain` icons sized smaller than the SVG's natural size (e.g. `w-3 h-3` on a 24px outline) only show a corner of the mask. Don't remove either.
- **Changelog**: v6.9.8 at `/admin/changelog`. Updated every push.
