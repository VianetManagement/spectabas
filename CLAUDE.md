# Spectabas — Developer Guide

## What is this?

Spectabas is a multi-tenant, privacy-first web analytics SaaS platform built with Elixir/Phoenix. It tracks pageviews and visitor behavior using a lightweight JavaScript tracker served from customer analytics subdomains (e.g. `b.dogbreederlicensing.org`).

## Tech Stack

- **Elixir 1.17 / Phoenix 1.8** with LiveView, scope-based auth (current_scope, not current_user)
- **PostgreSQL** — users, sites, sessions, visitors, audit logs (on Render, Ohio region)
- **ClickHouse** — event storage and analytics queries (Render private service, Ohio region)
- **Chart.js** — interactive charts (vendored UMD build, no CDN)
- **Render** — deployment platform (Docker-based)

## Architecture

### Data Flow
1. Website loads `/assets/v1.js` from analytics subdomain
2. Script sends beacon to `/c/e?s=<public_key>` (obfuscated endpoints)
3. CollectController validates payload, checks origin, resolves site by public key
4. Ingest.process enriches event (IP geo, UA parsing, session resolution, intent classification)
5. IngestBuffer batches events, flushes to ClickHouse every 500ms
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

Tests: `mix test` (182 tests, no ClickHouse needed)
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

### GeoIP Database Updates
- DB-IP + MaxMind refresh via Oban cron on 1st and 15th of each month at 06:00 UTC
- DB-IP downloaded during Docker build (cached layer, update monthly by bumping cache key)
- MaxMind downloaded at runtime on first startup if MAXMIND_LICENSE_KEY is set
- To update DB-IP manually: bump the date in the Dockerfile RUN command

## Dashboard Features

### Overview
- Time-series chart (Chart.js, pageviews + visitors)
- Stat cards with period comparison (vs previous equivalent period)
- Segment filters (filter by any dimension)
- Visitor intent breakdown

### Analytics Pages (sidebar navigation)
- **Behavior**: Pages, Entry/Exit, Page Transitions, Site Search
- **Acquisition**: Sources, Attribution, Campaigns (UTM builder)
- **Audience**: Geography, Visitor Map, Devices, Network, Visitor Log, Cohort Retention
- **Conversions**: Goals, Funnels, Ecommerce
- **Tools**: Reports, Exports, Settings

### Unique Features
- **Visitor Intent Detection** — auto-classifies visitors as buying/researching/comparing/support/returning/browsing/bot
- **Cross-linking** — click any dimension to navigate to filtered views (ASN→visitors, page→transitions, source→visitor log)
- **IP Cross-referencing** — visitor profiles show other visitors sharing the same IP
- **EU Flag** — GDPR compliance indicator from MaxMind

## Important Patterns

- **Auth**: Phoenix 1.8 scope-based. Access user via `socket.assigns.current_scope.user`
- **ClickHouse queries**: Always use `ClickHouse.param/1` for interpolated values
- **ClickHouse writes**: Use `ClickHouse.execute/1` for ALTER/UPDATE (write credentials)
- **Column names**: Must exactly match ClickHouse table (see events table in clickhouse.ex)
- **Geolix name maps**: Use both atom and string keys — `Map.get(names, "en") || Map.get(names, :en)`
- **Origin validation**: Auto-allows parent domain of analytics subdomain
- **Tracking subdomain plug**: Blocks all UI routes on analytics subdomains, only allows `/c/*`, `/assets/v1.js`, `/health`
- **Ad blocker evasion**: Script at `/assets/v1.js`, beacon uses public_key not domain, endpoints obfuscated
- **Cloudflare support**: Checks `CF-Connecting-IP` header before `x-forwarded-for`
- **Sidebar layout**: All dashboard pages use `<.dashboard_layout>` from SidebarComponent
- **Async dashboard**: Mount loads critical stats only; deferred stats load via `handle_info(:load_deferred)`
- **Chart updates**: Use `push_event` to push data to Chart.js hooks (not data attributes)
