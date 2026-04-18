# Spectabas — Developer Guide

## What is this?

Spectabas is a multi-tenant, privacy-first web analytics SaaS platform built with Elixir/Phoenix. It tracks pageviews and visitor behavior using a lightweight JavaScript tracker served from customer analytics subdomains (e.g. `b.dogbreederlicensing.org`).

## Tech Stack

- **Elixir 1.18 / Phoenix 1.8** with LiveView, scope-based auth (current_scope, not current_user)
- **PostgreSQL** — users, sites, sessions, visitors, audit logs (on Render, Ohio region)
- **ClickHouse** — event storage and analytics queries (Render private service, Ohio region)
- **Chart.js** — interactive charts (vendored UMD build, no CDN)
- **wax_** — WebAuthn/passkey 2FA support (FIDO2 hardware keys, platform authenticators)
- **tzdata** — timezone database for Elixir (required for site timezone support)
- **Render** — deployment platform (Docker-based)

## Architecture

### Data Flow
1. Website loads `/assets/v1.js` from analytics subdomain
2. Script sends beacon to `/c/e?s=<public_key>` (obfuscated endpoints)
3. CollectController validates payload, checks origin, resolves site by public key
4. Ingest.process enriches event (IP geo, UA parsing, session resolution, intent classification, visitor dedup)
5. IngestBuffer batches events (500 batch size), async flushes to ClickHouse via dedicated connection pool (100 connections)
6. Dashboard LiveViews query ClickHouse events table directly

### IP Enrichment Pipeline
- **DB-IP Lite** — primary geo (country, region, city, lat/lon, ASN)
- **MaxMind GeoLite2** — timezone, EU flag (downloaded at runtime via MAXMIND_LICENSE_KEY)
- **ASN Blocklists** — datacenter, VPN, TOR detection from priv/asn_lists/
- **UAInspector** — browser, OS, device type, bot detection
- **Intent Classifier** — buying, researching, comparing, support, returning, browsing, bot

### Key Endpoints (obfuscated)
- `/assets/v1.js` — tracker script
- `/c/e` — event collection (POST)
- `/c/p` — noscript pixel (GET)
- `/c/i` — user identification
- `/c/x` — cross-domain token
- `/c/o` — opt-out cookie
- `/api/v1/sites/:id/identify` — server-side visitor identification (POST)

### ClickHouse Schema
- Tables created by Elixir app on startup (`ensure_schema!` in ClickHouse module)
- Writer user needs INSERT + SELECT + ALTER UPDATE
- Column naming: `ip_country` not `country`, `duration_s` not `duration`, `referrer_url` not `referrer`
- `visitor_intent` — LowCardinality(String) for intent classification
- `ip_is_eu` — UInt8 flag from MaxMind EU detection
- Bloom filter skip indexes on: session_id, visitor_id, ip_country, browser, referrer_domain

### ClickHouse Data Types from JSON
**Important**: ClickHouse returns all values as strings in JSON format. Always use `to_num/1` or `to_float/1` helpers before arithmetic. This has caused multiple bugs.

**Important**: Ad effectiveness queries must use flat GROUP BY, not CTEs with JOINs — CTEs time out on ClickHouse with large event tables. A bloom_filter skip index on `click_id` speeds up `click_id != ''` filters. Revenue attribution first/last touch uses two parallel flat queries (visitor counts + revenue scoped to purchasing visitors) to avoid the timeout — "any" touch is small enough for a single query.

## Development

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

Tests: `mix test` (609 tests, no ClickHouse needed)
Format: `mix format`
Compile check: `mix compile --warnings-as-errors`

## Deployment

Push to `main` triggers auto-deploy on Render. Docker build ~2-3 minutes.

### Services (all Ohio region)
- Web: `srv-d72usa4r85hc73efqgpg` (Standard plan)
- ClickHouse: `srv-d72use0gjchc73as2rl0` (Standard plan, private service)
- PostgreSQL: `dpg-d72us1nkijhs73d77grg-a`

### Environment Variables
- `DATABASE_URL` — Render Postgres internal URL
- `SECRET_KEY_BASE` — generated
- `PHX_HOST` — `www.spectabas.com`
- `CLICKHOUSE_URL` — `http://spectabas-clickhouse:10000`
- `CLICKHOUSE_DB`, `CLICKHOUSE_WRITER_USER`, `CLICKHOUSE_WRITER_PASSWORD`
- `CLICKHOUSE_READER_USER`, `CLICKHOUSE_READER_PASSWORD`
- `RENDER_API_KEY`, `RENDER_SERVICE_ID` — for auto-registering custom domains
- `RESEND_API_KEY` — for email via Resend (from noreply@spectabas.com)
- `MAXMIND_LICENSE_KEY` — for GeoLite2 timezone/EU enrichment (optional, graceful fallback)
- `APPSIGNAL_PUSH_API_KEY` — AppSignal APM (error tracking, performance monitoring, Oban jobs)

### Adding a new tracked site
1. Create site in Admin > Sites (domain = analytics subdomain, e.g. `b.example.com`)
2. Domain auto-registers on Render
3. Add DNS CNAME: `b.example.com` → `www.spectabas.com` (gray cloud if Cloudflare)
4. Install snippet on target site (from site settings page)
5. Parent domain (e.g. `www.example.com`) is auto-allowed for origin checks

### Diagnostic endpoints
- `/health` — basic health check
- `/health/diag` — ClickHouse connectivity, event counts, GeoIP status, geo sample
- `/health/dashboard-test` — tests all analytics queries
- `/health/audit-test` — tests audit logging
- `/health/backfill-geo` — re-enriches events with empty geo data
- `/admin/ingest` — live ingest diagnostics (BEAM memory, buffer size, ETS cache stats, ClickHouse pool) — superadmin + platform_admin
- `/admin/api-logs` — API access logs with request/response detail modal (30-day retention)
- `/health/ecom-diag` — ecommerce diagnostics, supports `action=sync&start=YYYY-MM-DD&bg=1` for backfill
- `/health/fix-ch-schema` — adds missing ClickHouse columns (uses admin/default user for DDL)

### GeoIP Database Updates
- DB-IP + MaxMind refresh via Oban cron on 1st and 15th of each month at 06:00 UTC
- DB-IP downloaded during Docker build (cached layer, update monthly by bumping cache key)
- MaxMind downloaded at Docker build time if MAXMIND_LICENSE_KEY is set as build arg; falls back to runtime download on first startup
- To update DB-IP manually: bump the date in the Dockerfile RUN command

## Dashboard Features

### Overview
- Time-series chart (Chart.js, pageviews + visitors)
- Stat cards with period comparison (vs previous equivalent period)
- Segment filters (filter by any dimension) with saved segment presets
- Visitor intent breakdown

### Analytics Pages (sidebar navigation, 39 pages across 7 categories)
- **Overview**: Dashboard, Insights (8 anomaly types), Journeys (page-type grouping via content prefixes, outcome segmentation: converter/engaged/bounce, inline config panel), Realtime (visitor search/filter by email, IP, country)
- **Behavior**: Pages (device split column: Desktop/Mobile/Tablet %), Entry/Exit, Page Transitions, Site Search (stats cards, volume trend, top terms, search pages, configurable URL params), Outbound Links, Downloads, Events (clickable rows show property key/value breakdown via ARRAY JOIN JSONExtractKeysAndValues), Performance (RUM)
- **Acquisition**: Acquisition (channels with engagement metrics + sources with UTM tabs, consolidated from 3 pages), Campaigns (auto-detects from UTM events, one-click "Save to Builder"), Search Keywords (GSC + Bing)
- **Audience**: Geography, Visitor Map, Devices, Network, Bot Traffic (daily trend chart: bot vs human, clickable UA rows with detail modal), Scrapers, Visitor Log (sortable columns: Pages, Duration, Last Seen), Cohort Retention, Churn Risk
- **Conversions**: Goals (top 3 traffic sources per goal: source attribution), Funnels, Ecommerce, Revenue Attribution (sortable, paid/organic split with pills, First Click touch model: visitor's first-ever referrer across all history), Revenue Cohorts, Buyer Patterns, MRR & Subscriptions
- **Ad Effectiveness**: Visitor Quality (0-100 scoring), Time to Convert, Ad Visitor Paths, Ad-to-Churn, Organic Lift
- **Tools**: Reports, Email Reports, Exports, Settings (4 tabs: General, Content, Integrations, Advanced)
- Each category has a landing page at `/sites/:id/c/:category` with descriptions for every page

### Email Reports
- Per-user, per-site email digest subscriptions (daily/weekly/monthly)
- HTML emails with period comparison, top pages/sources/countries
- Oban cron dispatcher (every 15 min) + delivery worker with period-key idempotency
- One-click unsubscribe via signed Phoenix.Token (30-day validity)
- Settings UI on site settings page, admin subscriber view

### Unique Features
- **Visitor Intent Detection** — auto-classifies visitors as buying/engaging/researching/comparing/support/returning/browsing/bot. Site-configurable path patterns in Settings (intent_config map on sites table). "engaging" = core app usage (search, listings, messaging). Also: `journey_conversion_pages` (array of URL path prefixes) defines conversion pages for the Journeys page.
- **Row Evolution Sparklines** — click any row in the Pages table to see an inline trend chart for that page
- **Real User Monitoring** — Core Web Vitals (LCP, CLS, FID), page load timing, per-page and per-device performance. CWV over time chart (dual-axis: LCP+FID ms left, CLS right) on Performance page.
- **Cross-linking** — click any dimension to navigate to filtered views (ASN→visitors, page→transitions, source→visitor log)
- **IP Cross-referencing** — visitor profiles show other visitors sharing the same IP
- **EU Flag** — GDPR compliance indicator from MaxMind
- **Identified Users** — dashboard shows count and percentage of visitors with associated email (via server-side identify API)
- **Ecommerce on Dashboard** — sites with ecommerce enabled show revenue/orders/AOV cards on the main overview
- **Ecommerce Revenue Chart** — combined bar (revenue) + line (orders) chart on the ecommerce page
- **Ecommerce Email Association** — transaction API accepts `email` to link orders to visitor profiles; orders show on visitor detail page
- **Product Categories** — ecommerce items support optional `category` field for sub-types (e.g. new_subscription vs renewal); Top Products groups by name+category
- **Revenue Attribution** — which traffic sources generate paying customers; conversion rate, AOV, total revenue by source/campaign/medium
- **Revenue Cohorts** — LTV by first-purchase cohort week; heatmap of revenue per customer over time
- **Buyer Patterns** — lift analysis comparing buyer vs non-buyer page visits; side-by-side engagement stats
- **Scraper Detection** — weighted-signal scoring identifies likely scrapers: datacenter ASN (+40, suppressed for known VPN providers), spoofed mobile UA on datacenter IP (+20, also VPN-suppressed), IP rotation with same cookie (+20), escalating pageviews (20+ unique: +10, 50+: +15, 100+: +20, 200+: +25), systematic content crawl (+15), square resolution (+15, excludes social crawler ASNs), stale browser (+15, Chrome < v100), resolution-device mismatch (+10, smartphone UA + desktop resolution), robotic request timing (+10), no referrer (+10), emulator resolution (+5, only 800x600/1024x768/0x0). Score capped at 100. Three tiers: watching (40-69, log only), suspicious (70-84, tarpit), certain (85+, full countermeasures). Uses `uniqIf(url_path)` not `countIf` — refreshes/duration pings don't inflate scores. Per-site `scraper_content_prefixes` configurable in Settings. `Spectabas.Analytics.ScraperDetector` is a pure stateless module — no DB, no side effects. Scraper queries now pass `browser`, `browser_version`, and `device_type` to the profile for the new signals. Dashboard shows summary cards + sortable table + click-to-detail modal (opens visitor profile in new tab) with full UA, page paths, signals explained. Visitor profile pages show real-time scraper score + webhook status banner + delivery history.
- **Scraper Webhooks** — per-site webhook (URL + Bearer secret) fires POST at score 40+ (watching tier). Payload: visitor identifiers (IPs, ip_ranges, external_id, user_id), score, signals, activation_delay_hours (always 0 — recipient manages timing). When `datacenter_asn` signal fires, `ip_ranges` contains /64 CIDR prefixes for all IPv6 addresses. Re-fires on tier escalation (watching → suspicious → certain). Oban `ScraperWebhookScan` worker every 15 min. Tracks `scraper_webhook_sent_at` + `scraper_webhook_score` on visitors. Manual Send/Deactivate buttons on Scrapers page. Deactivation POST to `/api/webhooks/spectabas/scraper/deactivate`.
- **Churn Risk** — flags customers with 50%+ engagement decline (sessions, pages) over 14-day windows
- **Funnel Revenue** — funnels show revenue from visitors at each step (ecommerce sites only)
- **Abandoned Funnel Export** — CSV export of visitor IDs + emails who dropped off at each funnel step
- **Ad Platform Integrations** — Google Ads, Bing Ads, Meta/Facebook Ads OAuth2 connections with daily spend sync. Encrypted token storage (AES-256-GCM). Settings UI per site with Sync Now button. Oban sync every 6h. Google Ads account picker for MCC/multi-account setups.
- **Stripe Import** — Connect Stripe via API key (not OAuth) from Site Settings. Uses PaymentIntents API (pi_* IDs, NOT Charges API) to avoid overcounting. Syncs charges, refunds, and subscriptions via `StripeSync` Oban worker. Charges written to `ecommerce_events` with `import_source = "stripe"`, refunds update `refund_amount` column, subscriptions snapshot to `subscription_events` (ReplacingMergeTree). Matches to visitors via email lookup. API key needs Read access to: PaymentIntents, Customers, Refunds, Subscriptions, Prices, Products.
- **MRR & Subscriptions** — Dashboard page under Conversions showing current MRR, active/past_due/canceled subscription counts, plan breakdown, avg MRR per subscriber, recent cancellations (30d), and MRR trend bar chart (30d). Powered by daily subscription snapshots from Stripe/Braintree. MRR calculation: sum(unit_amount * quantity) per item, apply discount, normalize by billing interval (weekly/monthly/quarterly/annual).
- **Customer LTV** — Visitor profile page shows Lifetime Value card: net revenue (gross - refunds), total orders, refund total. Auto-populated from ecommerce_events.
- **Currency Formatting** — `Spectabas.Currency.format/2` renders amounts with proper symbols ($, EUR, GBP, JPY, etc.) instead of currency codes. Used across all revenue displays.
- **Braintree Import** — Connect Braintree via Merchant ID + Public/Private keys from Site Settings. Same capabilities as Stripe: transactions → ecommerce_events, refunds → refund_amount updates, subscriptions → subscription_events snapshots. Uses Braintree XML search API with Basic auth.
- **Configurable Sync Frequency** — Each integration has a per-integration sync frequency (5min to 24h) stored in `extra["sync_frequency_minutes"]`. Default: 15 min for payment providers (Stripe/Braintree), 6h for ad platforms. Oban cron runs every 5 min; `should_sync?/1` checks if enough time has elapsed since last sync.
- **Google Search Console** — OAuth2 integration syncing search queries, impressions, clicks, CTR, and position per page per day. Daily sync with 2-3 day delay. ClickHouse `search_console` table with ReplacingMergeTree.
- **Bing Webmaster** — API key integration syncing the same search metrics from Bing/Yahoo. Same ClickHouse table with `source` column distinguishing Google vs Bing.
- **Search Keywords Page** — Dashboard page under Acquisition showing top queries, top pages, sortable columns, source filter (Google/Bing/All), date range selector, position color-coding (green <=3, blue <=10, amber <=20, red >20). Includes position distribution, ranking changes (7d vs prior 7d), CTR opportunities, new/lost keywords.
- **AI-Powered Insights** — Weekly Insights page with AI analysis. Configure AI provider (Anthropic/OpenAI/Google) per site in Settings. "Generate Analysis" button sends aggregated metrics to AI for prioritized action items. Cached 24h. Weekly AI email sent Monday 9am UTC to email report subscribers.
- **Email Reports Enhanced** — Periodic email digest now includes top search keywords, revenue summary, and ad spend breakdown alongside traffic stats.
- **ROAS on Revenue Attribution** — Ad Spend Overview card (total spend, ad-attributed revenue, ROAS, clicks, impressions, per-platform breakdown). Campaign tab shows inline Spend/ROAS/CPC columns. Standalone Ad Spend by Campaign table on other tabs. ROAS color-coded.
- **Click ID Attribution** — Tracker captures gclid (Google), msclkid (Bing), fbclid (Meta) from landing URLs. Stored in ClickHouse `click_id`/`click_id_type` columns. Revenue from visitors with click IDs attributed to the platform for ROAS calculation.
- **Ad Effectiveness Suite** — 5 pages under new sidebar section: Visitor Quality (engagement scoring 0-100), Time to Convert (days/sessions to purchase), Ad Visitor Paths (page sequences by outcome), Ad-to-Churn (campaign churn correlation), Organic Lift (ad spend vs organic traffic correlation)
- **Revenue Attribution Enhancements** — sortable columns, paid vs organic row split with colored platform pills (Google/Bing/Meta) across all UTM tabs
- **Sidebar Anomaly Badges** — red/amber dots on sidebar section labels when `AnomalyDetector` finds issues. Only computed on main dashboard (deferred stats). `AnomalyBadges` module maps anomaly categories to sidebar sections.
- **Settings Tabs** — Settings page broken into 4 tabs (General, Content, Integrations, Advanced) for reduced cognitive load.
- **Reverse Proxy (data-proxy)** — tracker supports `data-proxy` attribute for same-origin tracking through main domain, bypasses ad blockers
- **External Identity Cookie** — sites configure a customer-set cookie name (e.g. `_puppies_fp`); tracker reads it and sends as `_xid`. Merges visitor profiles when `_sab` cookie changes but external identity persists. Configured per-site in Settings.

## Multi-Tenancy

### Account Model
- **Accounts** — tenant boundary grouping sites and users. Fields: name, slug (unique), site_limit (default 10), active.
- **Sites** and **Users** belong to an account via `account_id` FK.
- **Invitations** carry `account_id` — accepted users inherit the account.
- ClickHouse events keyed by `site_id` — account isolation is implicit (no CH changes needed).

### Role Hierarchy
| Role | Scope | account_id | Access |
|------|-------|------------|--------|
| platform_admin | Global | NULL | All accounts, sites, users. Creates accounts, invites superadmins. |
| superadmin | Account | set | Own account's sites/users. Can invite any role including superadmin. |
| admin | Account | set | Own account's sites. Cannot manage users. |
| analyst | Account+Site | set | Only explicitly-permitted sites within account. Can create goals/funnels/campaigns but cannot modify site settings or integrations. |
| viewer | Account+Site | set | Read-only on permitted sites within account. Cannot create or modify any resources — browse-only access. |

### Route Tiers
- `/platform/*` — platform_admin only (accounts management, spam filter, API logs, competitive)
- `/admin/*` — superadmin + platform_admin (account-scoped user/site management, audit, changelog)
- `/dashboard/*` — all authenticated users (analytics, scoped by `can_access_site?`)

### Key Functions
- `can_access_site?/2` — platform_admin→all; superadmin/admin→same account only; analyst/viewer→explicit permission + same account
- `accessible_sites/1` — scoped by account for superadmin/admin; all for platform_admin
- `list_users/1` — scoped to caller's account
- `invite_user/4` — requires account_id parameter
- `can_create_site?/1` — checks account site_limit
- `create_account/2` — platform_admin only

## Authentication

### Multi-factor Authentication
- **TOTP** — standard time-based one-time passwords (Google Authenticator, etc.)
- **WebAuthn/Passkeys** — FIDO2 hardware keys and platform authenticators via `wax_` library
- Users can register multiple WebAuthn credentials from account settings
- **Admin force 2FA** — admins can require 2FA for specific users from the admin panel
- **Account-level MFA enforcement** — platform admin can toggle `require_mfa` on accounts. Users without 2FA are redirected to setup on login.
- **2FA session gating** — `Require2FA` plug checks `totp_verified_at` session flag (12-hour validity). Verified via `/auth/2fa/verified` controller endpoint.
- **Granular site access** — Analyst/Viewer roles require explicit per-site permissions (toggled from /admin/users). Superadmin/Admin have account-scoped site access.

### SOC2 Security Controls
- **Password complexity** — min 12 chars, must include at least 1 letter and 1 number
- **Account lockout** — 5 failed login attempts per email = 15 min lockout (Hammer ETS). Audit logged.
- **Idle session timeout** — 30 min idle timeout with JS activity tracking, warning toast at 28 min. Users can opt out via Account Settings toggle.
- **Active session management** — session metadata (IP, user-agent, last_active_at) stored on `users_tokens`. Admin force-logout button.
- **Login link (forgot password)** — self-service on login page with honeypot field, timing check (2s min), 3-attempt rate limit per session. Generic success message prevents email enumeration.
- **Audit logging** — sign-in (with IP, method), sign-out, idle timeout, force logout, account lockout all recorded.

### wax_ Configuration
- Requires `origin` setting in `config/config.exs` (production) and `config/test.exs` (test)
- Example: `config :wax_, origin: "https://www.spectabas.com"`
- Test config must match the test environment origin or WebAuthn tests will fail

### API Keys
- Users can create/revoke API keys from account settings
- Creation UI with scope checkboxes, site restriction checkboxes, optional expiry date
- **Granular scopes**: `read:stats`, `read:visitors`, `write:events`, `write:identify`, `admin:sites`
- **Site restrictions**: tokens can be scoped to specific sites
- **Expiry**: optional expiration date on tokens
- **Key list UI**: shows scope badges, site restriction count, expiry status (expired=red, upcoming=yellow)
- **Access logging**: every API call logged with request/response bodies, 30-day retention, viewable at `/admin/api-logs`

### User Preferences
- **Timezone**: stored per-user (`timezone` field, default `America/New_York`). Used by admin pages (ingest diagnostics, API logs) for local time display. Selectable via dropdown on admin pages.

## Security

### Audit v1 (v0.8.0) — 10 findings fixed
1. Auth on health endpoints 2. Opt-out cookie check 3. Login rate limiting
4. Invitation email verification 5. Null byte sanitization 6. Buffer overflow protection
7. ClickHouse TTL 8. MMDB integrity checks 9. Input validation 10. Session fixation

### Audit v2 (v1.6.0) — 10 findings fixed
1. **WebAuthn binary_to_term :safe** — prevents code execution if DB is compromised
2. **WebAuthn credential ownership** — deletion requires user_id match, prevents cross-user deletion
3. **Pixel opt-out** — `/c/p` noscript pixel now respects `_sab_optout` cookie (GDPR regression)
4. **Origin validation** — fixed bypass when Origin empty but Referer present
5. **API date range cap** — custom ranges capped at 12 months to prevent ClickHouse DoS
6. **Config secrets** — removed default ClickHouse passwords from committed config
7. **CSP object-src** — added `object-src 'none'` to Content-Security-Policy
8. **Cookie security** — remember-me cookie gets `secure` and `http_only` flags
9. **Health endpoint** — public `/health` returns only `ok/degraded`, no internal details
10. **SQL parameterization** — backfill-geo lat/lon/asn use `ClickHouse.param/1`

### Audit v3 (v2.6.0) — 5 findings fixed
1. **SQL injection** — `visitor_log` per_page interpolated raw into SQL; now uses `ClickHouse.param/1` with clamped range
2. **Segment IDOR** — `get_segment!` had no ownership check; now scopes by user_id and site_id
3. **Origin validation** — `/c/i` (identify) and `/c/x` (cross-domain) lacked origin checks and opt-out cookie validation
4. **Silent event loss** — `Ingest.process` errors were caught as crashes via pattern match in try/rescue; now uses explicit case handling
5. **Deferred stats sequential** — 9 dashboard queries ran sequentially (~1s); now parallel via Task.async (~200ms)

### Audit v4 (v4.8.0) — 5 findings fixed
1. **IP spoofing** — `CF-Connecting-IP` trusted before `X-Forwarded-For`; reversed priority so Render's LB header is trusted first
2. **Hardcoded utility token** — `sab_import_test_92f7a3b1` in source code; replaced with `UTILITY_TOKEN` env var
3. **Field length validation** — `_fp`, `_cid`, `_cidt` lacked length limits in CollectPayload; added max 256/256/32
4. **LIKE wildcard injection** — segment `contains`/`not_contains` didn't escape `%`/`_`; now escaped before LIKE pattern
5. **Click ID format validation** — gclid/msclkid/fbclid accepted without validation; now checked for length (5-256) and character set (alphanumeric + `-_=.`)

## UI/UX

- **Sidebar navigation** — color-coded categories (Behavior, Acquisition, Audience, Conversions, Tools)
- **Cross-linking** — click any dimension value to navigate to filtered views across analytics pages
- **Mobile responsiveness** — scrollable tables, collapsible mobile nav bar
- **Accessible top nav** — WCAG AA contrast compliance
- **Documentation pages** — docs split into `/docs` (index), `/docs/getting-started`, `/docs/dashboard`, `/docs/conversions`, `/docs/api`, `/docs/admin` with cross-category search. Requires login (behind :require_authenticated_user). Public pages: `/privacy`, `/terms`, homepage.
- **Changelog** — versioned changelog at `/admin/changelog`, updated on every push (current: v5.61.0)
- **Legal** — Privacy Policy at `/privacy` and Terms of Service at `/terms` (public, no auth required). Entity: Spectabas, Kent County MI. Contact: howdy@spectabas.com. Arbitration clause (AAA, Kent County). 18+ age restriction.

## Important Patterns

- **Auth**: Phoenix 1.8 scope-based. Access user via `socket.assigns.current_scope.user`
- **ClickHouse queries**: Always use `ClickHouse.param/1` for interpolated values
- **ClickHouse writes**: Use `ClickHouse.execute/1` for ALTER/UPDATE (write credentials)
- **Column names**: Must exactly match ClickHouse table (see events table in clickhouse.ex)
- **Geolix name maps**: Use both atom and string keys — `Map.get(names, "en") || Map.get(names, :en)`
- **Origin validation**: Auto-allows parent domain of analytics subdomain
- **Tracking subdomain plug**: Blocks all UI routes on analytics subdomains, only allows `/c/*`, `/assets/v1.js`, `/health`
- **Spam filter**: `Spectabas.Analytics.SpamFilter` maintains builtin + DB-stored spam domains, auto-excluded from Sources/Channels queries. Admin page at `/admin/spam-filter` for managing blocklist with auto-detection of suspicious referrer domains. Daily Oban worker (`SpamDetector`) scans for candidates.
- **Site search params**: Configurable per-site `search_query_params` array (Settings > Content). Ingest checks site's params first, falls back to defaults (`q`, `query`, `search`, `s`, `keyword`). Extracted values stored as `_search_query` and `_search_param` in event properties. Site Search page shows config banner with tracked params, filter pills by parameter, and param badges on each search term row.
- **Pageview rate limiting**: Tracker uses sessionStorage to enforce 5-second minimum interval between pageviews for the same pathname (not full URL). Query-string-only changes (search filters, pagination) don't trigger new pageviews. Prevents overcounting from rapid refreshes, auto-refresh, or iframe reloads.
- **SPA pageview tracking**: Only pathname changes trigger new pageviews. Query-string-only pushState changes are ignored. This matches standard analytics behavior (Matomo, GA).
- **Saved segments**: Ownership enforced — `get_segment!/3` scopes by user_id and site_id. Never load segments by ID alone.
- **Tracker GDPR default**: `data-gdpr` defaults to `"off"` (cookie-based). Sites needing fingerprint-only mode must explicitly set `data-gdpr="on"`.
- **Click ID capture**: Tracker extracts gclid/msclkid/fbclid from URL, persists in sessionStorage, sends as `_cid`/`_cidt` fields. Ingest validates format (5-256 chars, alphanumeric + `-_=.` only) before storing in `click_id`/`click_id_type` ClickHouse columns. Invalid click IDs silently dropped. Revenue Attribution uses click IDs for platform-level ROAS.
- **Ad blocker evasion**: Script at `/assets/v1.js`, beacon uses public_key not domain, endpoints obfuscated. `data-proxy` attribute enables reverse proxy through main domain for same-origin tracking. Cookie is always set on the page domain (not the script origin), so no cookie migration needed when switching to proxy mode. Proxy plug MUST go in endpoint.ex before Plug.Parsers (not router.ex). Cloudflare Bot Fight Mode must be disabled or have WAF skip rule for `/t/*` — sendBeacon cannot solve JS challenges.
- **IP extraction**: Priority: `X-Spectabas-Real-IP` (trusted proxy header) > `X-Forwarded-For` (Render LB) > `CF-Connecting-IP` (Cloudflare fallback) > `conn.remote_ip`. The custom header is set by our reverse proxy plug and survives Render's XFF overwrite on the second hop. Both `ingest.ex` and `collect_rate_limit.ex` use the same priority.
- **Category landing pages**: `/sites/:id/c/:category` renders hub page with descriptions for each page in the category. Single reusable LiveView (`CategoryLive`) with all 39 page descriptions. Sidebar section labels link to these.
- **Sidebar layout**: All dashboard pages use `<.dashboard_layout>` from SidebarComponent
- **Flash messages**: Unified modal toast in top-right corner (defined in SidebarComponent). Info auto-dismisses via AutoDismiss hook; errors persist until closed. Do NOT add inline flash rendering in individual pages — the layout handles it.
- **Button styling**: All buttons use `rounded-lg`. Primary: `inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm`. Secondary: `px-3 py-1.5` with colored text/bg/border and `rounded-lg`.
- **Async dashboard**: Mount loads critical stats (stats cards + timeseries + realtime count) synchronously, then kicks off deferred queries via `handle_info(:load_deferred)`. Deferred queries are **progressive** — each query is spawned as an unlinked `Task.start` that sends its result back via `{:deferred_result, assign_key, value, cache_key}`. `handle_info` updates one assign and the LiveView re-renders just that card. `cache_key` (matches `stats_cache_key/1`) guards against stale results when the user switches ranges mid-load. The slowest query no longer blocks the whole section. Deferred keys: `top_pages`, `top_sources`, `top_regions`, `top_browsers`, `top_os`, `entry_pages`, `locations`, `timezones`, `intents`, `identified_users`, `ecommerce` (conditional).
- **Dashboard slow-query log**: Critical and deferred dashboard queries are wrapped by `timed/4` in `site_live.ex`. Any query over 500ms logs `[Dashboard:slow] <name> site=<id> days=<n> took=<ms>ms` at notice level. Use this to identify the bottleneck for any dashboard page — Render logs and AppSignal both capture it.
- **Chart updates**: Use `push_event` to push data to Chart.js hooks (not data attributes)
- **Chart.js initial-data pattern**: `push_event` called during `mount` is unreliable — hook `mounted()` can run before the event buffer drains and the push is silently dropped. The robust pattern (used by SearchKeywordsLive) is to JSON-encode the chart data into a `data-chart` attribute on the hook element. The hook reads `this.el.dataset.chart` in `mounted()` — the data is in the DOM by then, no race. For updates on user interaction (range change, etc.), render a `chart_key` suffix on the DOM id (e.g. `id={"chart-foo-" <> @chart_key}`) that changes on every reload — LiveView will swap the whole element and the hook will remount fresh. Still add `phx-update="ignore"` so LV doesn't touch the Chart.js-managed canvas between reloads. `push_event` can still be used alongside for live updates — the Sparkline and SearchChart hooks listen for both. Affected so far: SearchKeywordsLive (fully migrated), SiteLive main dashboard chart (still uses push_event but it works because there's only one and it pushes from load_critical_stats which runs synchronously during mount).
- **Fast timeseries**: For date ranges >= 30 days, use `Analytics.timeseries_fast/4` which queries the `daily_rollup` AggregatingMergeTree for complete prior days and raw events only for today + yesterday (2-day buffer for the cron-delay gap). Short ranges use `Analytics.timeseries/4` for hourly granularity. Both paths use `uniqExactIf(visitor_id, event_type='pageview')` to match `overview_stats` exactly. Never use the old `daily_stats` SummingMergeTree for visitor counts — it sums per-batch uniqExact values and inflates.
- **Rollup tables (AggregatingMergeTree)**: 5 tables populated by `Spectabas.Workers.DailyRollup` (daily cron at 01:30 UTC + one-shot `%{"backfill" => true}` for historical backfill). All use `countIfState`/`uniqExactIfState` filtered to `event_type='pageview' AND ip_is_bot=0`. Query with `countIfMerge` / `uniqExactIfMerge` (note: -If combinator must stay in the Merge name).
  - `daily_rollup` — (site_id, date) → pageviews, visitors, sessions. Used by `timeseries_fast` and `overview_stats_fast`.
  - `daily_page_rollup` — (site_id, date, url_path) → pageviews, visitors. Used by `top_pages_fast`.
  - `daily_source_rollup` — (site_id, date, referrer_domain) → pageviews, sessions. Used by `top_sources_fast`.
  - `daily_geo_rollup` — (site_id, date, ip_country, ip_region_name, ip_city, ip_lat, ip_lon, ip_timezone) → pageviews, visitors. Used by `top_regions_fast`, `visitor_locations_fast`, `timezone_distribution_fast`.
  - `daily_device_rollup` — (site_id, date, device_type, browser, os) → pageviews, visitors. Used by `top_browsers_fast`, `top_os_fast`.
- **Rollup query pattern**: Complete prior days come from the rollup (cheap uniqExactIfMerge); today+yesterday (UTC) come from raw events as states, UNION ALL'd into a single outer merge for exact cross-day dedup. Segmented queries fall back to raw-events paths because rollups are unsegmented. Detail pages (PagesLive, SourcesLive, GeoLive, MapLive, DevicesLive) keep using raw-events `Analytics.top_*` (non-fast) variants for full detail including avg_duration, city drill-down, etc.
- **Rollup idempotency**: Re-runs for the same date DELETE existing rows first via `ALTER TABLE <table> DELETE WHERE date = X SETTINGS mutations_sync=2`. `uniqExactIfState` merges via set union so it would be idempotent alone, but `countIfState` merges via sum — so deletion is required.
- **AI integration**: Per-site AI config in `ai_config_encrypted` (same pattern as ad credentials). `Spectabas.AI.Completion.generate/3` abstracts Anthropic/OpenAI/Google. `InsightsCache` caches AI analysis for 24h. Weekly AI email via `AIWeeklyEmail` Oban worker (Monday 9am UTC).
- **Visitor dedup**: In GDPR-off (cookie) mode, new cookie = new visitor. No fingerprint merging. Fingerprint-based dedup only applies in GDPR-on (cookieless) mode via `Visitors.find_by_fingerprint/2`
- **External identity cookie**: Sites can configure `identity_cookie_name` (e.g. `_puppies_fp`) in Settings. Tracker reads this cookie from the customer's domain via `data-xid-cookie` attribute and sends its value as `_xid`. Ingest resolves visitors by `external_id` first — if `_sab` cookie changes but `_xid` matches an existing visitor, the visitor is merged (cookie_id updated). `external_id` stored on visitors table with partial index `(site_id, external_id) WHERE external_id IS NOT NULL`. Only works in GDPR-off (cookie) mode.
- **Timezone handling**: Requires `tzdata` library — without it, `DateTime.shift_zone` silently fails to UTC. All dashboard date boundaries use site timezone via `dates_to_utc_range/3`. Rolling periods (24h, 7d, 30d) are UTC-relative and timezone-independent. Only "Today" and date-picker ranges need timezone conversion. All ClickHouse queries that return displayed timestamps use `toTimezone(timestamp, site.timezone)` via the `tz_sql/1` helper. Admin pages use user's personal timezone preference for Postgres timestamps.
- **Query consistency**: ALL analytics queries showing visitor/pageview/session counts MUST include `ip_is_bot = 0` and filter to pageview events. Exceptions: network_stats (shows bot %), realtime (all live activity), visitor detail pages, RUM queries. This ensures numbers match across dashboard, channels, sources, geography, etc.
- **Bounce rate**: Industry-standard definition — `countIf(pv = 1)` — sessions with exactly 1 pageview. Do NOT factor in duration or custom events; those measure engagement, not bounce.
- **Bot vs datacenter**: `ip_is_bot` is set ONLY from UA detection (navigator.webdriver, headless browser). Datacenter IPs are tracked via `ip_is_datacenter` but are NOT automatically flagged as bots — VPN and corporate proxy users are real visitors.
- **VPN provider detection**: ipapi.is VPN MMDB databases (enumerated + interpolated) auto-downloaded on boot and refreshed bi-monthly via GeoIPRefresh worker. Set `IPAPI_API_KEY` env var. `ip_vpn_provider` stores the provider name (e.g. "NordVPN", "ProtonVPN") in ClickHouse events. `ip_is_vpn` flag is set when either ASN blocklist OR MMDB matches. ScraperDetector suppresses `datacenter_asn` and `spoofed_mobile_ua` signals when visitor is on a known consumer VPN. Admin page at `/admin/geoip` shows all database statuses and download history.
- **Origin validation**: Allows any subdomain of the parent domain (e.g., `app.example.com` is allowed when analytics domain is `b.example.com`). Cross-domain sites list is for entirely separate domains.
- **API token scopes**: Enforce scope checks in API controllers. `read:stats` for GET stats/pages/sources, `read:visitors` for visitor log, `write:events` for event collection, `write:identify` for server-side identify, `admin:sites` for site management. Tokens can be restricted to specific site IDs.
- **API access logging**: Every API call is logged (endpoint, method, request body, response status, response body). Stored in PostgreSQL with 30-day retention via Oban cleanup worker. Admin UI at `/admin/api-logs` with detail modal.
- **High-throughput ingest**: Async flush, 500 batch size, ETS visitor cache, dedicated ClickHouse connection pool (100 connections), per-site rate limiting (1000 events/sec). Crash recovery: buffer persisted to `/tmp` every 10s, recovered on restart.
- **ObanRepo**: Dedicated Postgres connection pool (25 connections) for Oban background jobs, isolated from the web pool (10 connections). Same database, separate pools. Prevents sync workers from starving web requests.
- **Backpressure**: IngestBuffer returns 503 when buffer exceeds soft limit (5,000). Health endpoint returns "overloaded" when buffer >= 8,000 or Oban queue >= 500,000 pending jobs.
- **occurred_at backdating**: All events support optional `occurred_at` field (Unix UTC seconds) to backdate events up to 7 days.
- **Ecommerce email association**: Transaction API accepts optional `email` field. If `visitor_id` + `email` both provided, identifies the visitor. If only `email`, looks up by email. Orders appear on visitor profile pages.
- **Ad integrations**: OAuth2 tokens stored encrypted via `Spectabas.AdIntegrations.Vault` (AES-256-GCM from SECRET_KEY_BASE). Platform adapters in `lib/spectabas/ad_integrations/platforms/`. Sync worker `AdSpendSync` runs every 6h via Oban `:ad_sync` queue. ClickHouse `ad_spend` table uses `ReplacingMergeTree(synced_at)` for dedup — **all queries MUST use `FROM ad_spend FINAL`** to deduplicate rows from repeated syncs. ROAS = revenue / spend, matched by campaign_name = utm_campaign.
- **Ad platform credentials**: Stored per-site as encrypted JSON blob in `sites.ad_credentials_encrypted`. No environment variables needed. Managed via `Spectabas.AdIntegrations.Credentials` module. Each site configures its own OAuth app credentials from the Settings page.
- **ClickHouse argMinIf/argMaxIf empty string**: These functions return `''` (empty string, not NULL) when no rows match the condition. Always wrap with `nullIf(..., '')` before `ifNull` fallback, e.g. `ifNull(nullIf(argMinIf(expr, ts, cond), ''), 'Direct')`.
- **ClickHouse alias collisions with source columns**: Never alias a projection to the same name as an underlying column. Two distinct failure modes, both surfacing in SearchKeywordsLive:
  - `sum(clicks) AS clicks` → `sum(clicks)` elsewhere resolves to `sum(<alias>)` = nested aggregation → `ILLEGAL_AGGREGATION (Code 184)`.
  - `toString(date) AS date` when the source column `date` is type Date → GROUP BY / ORDER BY can't decide between source column (Date) and alias (String) → `NO_COMMON_TYPE (Code 386)` "no supertype for String, Date".
  Worse still: with `FROM table FINAL`, ClickHouse sometimes silently returns 0 rows instead of the error. Fix: use distinct alias names (`total_clicks`, `bucket`, `daily_clicks`, etc.). Keep GROUP BY/ORDER BY on the source column name when possible — it reads clearer and avoids any resolution ambiguity.
- **ClickHouse LEFT JOIN + non-Nullable columns**: Non-Nullable columns (e.g., `Decimal(12,2) DEFAULT 0`) return their default value (0), not NULL, on LEFT JOIN misses. Never use `avg()` on such columns across a LEFT JOIN — use `sum(col) / greatest(countDistinct(id), 1)` instead, or the average will be diluted by zeros.
- **RUM collection**: Tracker sends `_rum` (nav timing) and `_cwv` (Core Web Vitals) custom events. Uses `performance.getEntriesByType("navigation")` with `performance.timing` fallback. IMPORTANT: PerformanceNavigationTiming uses `nav.startTime` (always 0) for the navigation baseline — NOT `nav.navigationStart` which only exists on the deprecated `performance.timing`. Queries use `quantileIf` to exclude zeros. ClickHouse `quantileIf` returns `nan` when no rows match — `parse_rows` sanitizes `nan`→`null` before JSON parsing.
- **Braintree pagination**: Braintree search API returns max 50 results per request. Uses two-step search: (1) POST to `advanced_search_ids` to get ALL matching transaction IDs, (2) batch-fetch full data via `advanced_search` with `<ids>` element in chunks of 50. The `advanced_search` endpoint alone only returns 50 results with no reliable pagination — `total-items` just reflects the current page count, not the true total. `fetch_all_by_ids/3` handles this for both transactions and refunds.
- **Stripe PaymentIntents vs Charges**: Always use `/v1/payment_intents` (pi_* IDs), NOT `/v1/charges` (ch_* IDs). Charges can have multiples per payment (e.g. auth + capture), causing overcounting. PaymentIntents represent a single logical payment.
- **Ecommerce source filtering**: When ANY Stripe integration record exists (active or not), revenue dashboards filter to `import_source = 'stripe'` only (pi_* orders). Prevents double-counting with API-submitted transactions.
- **import_source column**: `ecommerce_events` has `import_source` LowCardinality(String) — values: `"stripe"`, `"braintree"`, `""` (API). Clear Data only deletes rows matching that integration's source. This prevents one integration's Clear Data from wiping another's data.
- **Integration mark_error**: Does NOT change status to "error" — keeps `status: "active"` so cron continues retrying. Only stores error message and increments error count.
- **Sync lock**: `persistent_term`-based lock per integration ID prevents concurrent sync runs from inserting duplicate data.
- **Smart sync with catchup**: Payment sync (Stripe/Braintree) fetches today only. If last successful sync was > 6h ago, yesterday is included to prevent data gaps after outages. Historical backfill checks ClickHouse for existing data before calling payment APIs.
- **Slack notifications**: `Spectabas.Notifications.Slack` sends alerts via incoming webhook. Set `SLACK_WEBHOOK_URL` env var. Used for sync failures; available for other alerts.
- **ClickHouse schema migrations**: `CREATE TABLE IF NOT EXISTS` does NOT add new columns to existing tables. Use `ALTER TABLE ADD COLUMN IF NOT EXISTS` for new columns on existing tables.
- **ClickHouse OPTIMIZE DEDUPLICATE BY**: Must include ALL ORDER BY columns in the BY clause, not just a subset.
- **Integration auto-repair**: Settings page `mount` calls `auto_repair_integrations/1` to fix orphaned records (credentials exist but no integration record). Integration records also auto-created on first sync.
- **Session token encryption**: OAuth tokens stored in session cookies are encrypted via `Spectabas.AdIntegrations.Vault` before storage.
- **Integration credential masking**: Saved API keys/secrets show as masked (`****...last4`) in form fields. Full values only stored, never re-displayed.
- **Integration IDOR protection**: `authorize_integration!/2` verifies the integration belongs to the current site before any operation (sync, clear, delete).
- **Integration HTTP retry**: All integration API calls use `Spectabas.AdIntegrations.HTTP` instead of raw `Req`. Wraps get/post with 3-attempt retry on TransportError with exponential backoff. New integrations must use this module.
- **Campaign ID resolution**: Revenue Attribution matches `utm_campaign` to ad spend by both `campaign_name` AND `campaign_id`. When utm_campaign contains an ID, the display resolves to the human-readable name from the ad platform. The `ad_spend_by_campaign/3` query returns both `campaign_id` and `campaign_name`.
- **ecom-diag endpoint**: Supports `action=sync&start=YYYY-MM-DD&bg=1` for historical backfill in background.
- **fix-ch-schema endpoint**: Uses `execute_admin` (ClickHouse default user) for DDL operations since writer user may lack ALTER TABLE privileges for schema changes.
- **Subscription MRR calculation**: `sum(unit_amount * quantity)` across all subscription items, apply percentage/fixed discount, normalize by billing interval (weekly×4.33, monthly×1, quarterly÷3, annual÷12).
