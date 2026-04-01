# Spectabas — Developer Guide

## What is this?

Spectabas is a multi-tenant, privacy-first web analytics SaaS platform built with Elixir/Phoenix. It tracks pageviews and visitor behavior using a lightweight JavaScript tracker served from customer analytics subdomains (e.g. `b.dogbreederlicensing.org`).

## Tech Stack

- **Elixir 1.17 / Phoenix 1.8** with LiveView, scope-based auth (current_scope, not current_user)
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
5. IngestBuffer batches events (1000 batch size), async flushes to ClickHouse via dedicated connection pool (100 connections)
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

## Development

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

Tests: `mix test` (458 tests, no ClickHouse needed)
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
- `/admin/ingest` — live ingest diagnostics (BEAM memory, buffer size, ETS cache stats, ClickHouse pool)
- `/admin/api-logs` — API access logs with request/response detail modal (30-day retention)

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

### Analytics Pages (sidebar navigation)
- **Behavior**: Pages, Entry/Exit, Page Transitions, Site Search, Outbound Links, Downloads, Events, Performance (RUM)
- **Acquisition**: All Channels, Sources (6 UTM tabs), Attribution, Campaigns (UTM builder)
- **Audience**: Geography, Visitor Map, Devices, Network, Bot Traffic, Visitor Log, Cohort Retention
- **Conversions**: Goals, Funnels, Ecommerce
- **Tools**: Reports, Email Reports, Exports, Settings

### Email Reports
- Per-user, per-site email digest subscriptions (daily/weekly/monthly)
- HTML emails with period comparison, top pages/sources/countries
- Oban cron dispatcher (every 15 min) + delivery worker with period-key idempotency
- One-click unsubscribe via signed Phoenix.Token (30-day validity)
- Settings UI on site settings page, admin subscriber view

### Unique Features
- **Visitor Intent Detection** — auto-classifies visitors as buying/researching/comparing/support/returning/browsing/bot
- **Row Evolution Sparklines** — click any row in the Pages table to see an inline trend chart for that page
- **Real User Monitoring** — Core Web Vitals (LCP, CLS, FID), page load timing, per-page and per-device performance
- **Cross-linking** — click any dimension to navigate to filtered views (ASN→visitors, page→transitions, source→visitor log)
- **IP Cross-referencing** — visitor profiles show other visitors sharing the same IP
- **EU Flag** — GDPR compliance indicator from MaxMind
- **Identified Users** — dashboard shows count and percentage of visitors with associated email (via server-side identify API)
- **Ecommerce on Dashboard** — sites with ecommerce enabled show revenue/orders/AOV cards on the main overview
- **Ecommerce Revenue Chart** — combined bar (revenue) + line (orders) chart on the ecommerce page
- **Ecommerce Email Association** — transaction API accepts `email` to link orders to visitor profiles; orders show on visitor detail page

## Authentication

### Multi-factor Authentication
- **TOTP** — standard time-based one-time passwords (Google Authenticator, etc.)
- **WebAuthn/Passkeys** — FIDO2 hardware keys and platform authenticators via `wax_` library
- Users can register multiple WebAuthn credentials from account settings
- **Admin force 2FA** — admins can require 2FA for specific users from the admin panel

### wax_ Configuration
- Requires `origin` setting in `config/config.exs` (production) and `config/test.exs` (test)
- Example: `config :wax_, origin: "https://www.spectabas.com"`
- Test config must match the test environment origin or WebAuthn tests will fail

### API Keys
- Users can create/revoke API keys from account settings
- Used for programmatic access to analytics data
- **Granular scopes**: `read:stats`, `read:visitors`, `write:events`, `write:identify`, `admin:sites`
- **Site restrictions**: tokens can be scoped to specific sites
- **Expiry**: optional expiration date on tokens
- **Access logging**: every API call logged with request/response bodies, 30-day retention, viewable at `/admin/api-logs`

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

## UI/UX

- **Sidebar navigation** — color-coded categories (Behavior, Acquisition, Audience, Conversions, Tools)
- **Cross-linking** — click any dimension value to navigate to filtered views across analytics pages
- **Mobile responsiveness** — scrollable tables, collapsible mobile nav bar
- **Accessible top nav** — WCAG AA contrast compliance
- **Documentation page** — comprehensive docs at `/docs`
- **Changelog** — versioned changelog at `/admin/changelog`, updated on every push

## Important Patterns

- **Auth**: Phoenix 1.8 scope-based. Access user via `socket.assigns.current_scope.user`
- **ClickHouse queries**: Always use `ClickHouse.param/1` for interpolated values
- **ClickHouse writes**: Use `ClickHouse.execute/1` for ALTER/UPDATE (write credentials)
- **Column names**: Must exactly match ClickHouse table (see events table in clickhouse.ex)
- **Geolix name maps**: Use both atom and string keys — `Map.get(names, "en") || Map.get(names, :en)`
- **Origin validation**: Auto-allows parent domain of analytics subdomain
- **Tracking subdomain plug**: Blocks all UI routes on analytics subdomains, only allows `/c/*`, `/assets/v1.js`, `/health`
- **Spam filter**: `Spectabas.Analytics.SpamFilter` maintains builtin + DB-stored spam domains, auto-excluded from Sources/Channels queries. Admin page at `/admin/spam-filter` for managing blocklist with auto-detection of suspicious referrer domains. Daily Oban worker (`SpamDetector`) scans for candidates.
- **Pageview rate limiting**: Tracker uses sessionStorage to enforce 5-second minimum interval between pageviews for the same pathname (not full URL). Query-string-only changes (search filters, pagination) don't trigger new pageviews. Prevents overcounting from rapid refreshes, auto-refresh, or iframe reloads.
- **SPA pageview tracking**: Only pathname changes trigger new pageviews. Query-string-only pushState changes are ignored. This matches standard analytics behavior (Matomo, GA).
- **Saved segments**: Ownership enforced — `get_segment!/3` scopes by user_id and site_id. Never load segments by ID alone.
- **Tracker GDPR default**: `data-gdpr` defaults to `"off"` (cookie-based). Sites needing fingerprint-only mode must explicitly set `data-gdpr="on"`.
- **Ad blocker evasion**: Script at `/assets/v1.js`, beacon uses public_key not domain, endpoints obfuscated
- **Cloudflare support**: Checks `CF-Connecting-IP` header before `x-forwarded-for`
- **Sidebar layout**: All dashboard pages use `<.dashboard_layout>` from SidebarComponent
- **Async dashboard**: Mount loads critical stats only; deferred stats load via `handle_info(:load_deferred)`
- **Chart updates**: Use `push_event` to push data to Chart.js hooks (not data attributes)
- **Visitor dedup**: In GDPR-off (cookie) mode, new cookie = new visitor. No fingerprint merging. Fingerprint-based dedup only applies in GDPR-on (cookieless) mode via `Visitors.find_by_fingerprint/2`
- **Timezone handling**: Requires `tzdata` library — without it, `DateTime.shift_zone` silently fails to UTC. All dashboard date boundaries use site timezone via `dates_to_utc_range/3`. Rolling periods (24h, 7d, 30d) are UTC-relative and timezone-independent. Only "Today" and date-picker ranges need timezone conversion.
- **Query consistency**: ALL analytics queries showing visitor/pageview/session counts MUST include `ip_is_bot = 0` and filter to pageview events. Exceptions: network_stats (shows bot %), realtime (all live activity), visitor detail pages, RUM queries. This ensures numbers match across dashboard, channels, sources, geography, etc.
- **Bot vs datacenter**: `ip_is_bot` is set ONLY from UA detection (navigator.webdriver, headless browser). Datacenter IPs are tracked via `ip_is_datacenter` but are NOT automatically flagged as bots — VPN and corporate proxy users are real visitors.
- **Origin validation**: Allows any subdomain of the parent domain (e.g., `app.example.com` is allowed when analytics domain is `b.example.com`). Cross-domain sites list is for entirely separate domains.
- **API token scopes**: Enforce scope checks in API controllers. `read:stats` for GET stats/pages/sources, `read:visitors` for visitor log, `write:events` for event collection, `write:identify` for server-side identify, `admin:sites` for site management. Tokens can be restricted to specific site IDs.
- **API access logging**: Every API call is logged (endpoint, method, request body, response status, response body). Stored in PostgreSQL with 30-day retention via Oban cleanup worker. Admin UI at `/admin/api-logs` with detail modal.
- **High-throughput ingest**: Async flush, 1000 batch size, ETS visitor cache, dedicated ClickHouse connection pool (100 connections), per-site rate limiting (1000 events/sec).
- **occurred_at backdating**: All events support optional `occurred_at` field (Unix UTC seconds) to backdate events up to 7 days.
- **Ecommerce email association**: Transaction API accepts optional `email` field. If `visitor_id` + `email` both provided, identifies the visitor. If only `email`, looks up by email. Orders appear on visitor profile pages.
- **RUM collection**: Tracker sends `_rum` (nav timing) and `_cwv` (Core Web Vitals) custom events. Uses `performance.getEntriesByType("navigation")` with `performance.timing` fallback. IMPORTANT: PerformanceNavigationTiming uses `nav.startTime` (always 0) for the navigation baseline — NOT `nav.navigationStart` which only exists on the deprecated `performance.timing`. Queries use `quantileIf` to exclude zeros. ClickHouse `quantileIf` returns `nan` when no rows match — `parse_rows` sanitizes `nan`→`null` before JSON parsing.
