# Spectabas — Developer Guide

## What is this?

Spectabas is a multi-tenant, privacy-first web analytics SaaS platform built with Elixir/Phoenix. It tracks pageviews and visitor behavior using a lightweight JavaScript tracker served from customer analytics subdomains (e.g. `b.dogbreederlicensing.org`).

## Tech Stack

- **Elixir 1.17 / Phoenix 1.8** with LiveView, scope-based auth (current_scope, not current_user)
- **PostgreSQL** — users, sites, sessions, audit logs (on Render, Ohio region)
- **ClickHouse** — event storage and analytics queries (Render private service, Ohio region)
- **Render** — deployment platform (Docker-based)

## Architecture

### Data Flow
1. Website loads `/assets/v1.js` from analytics subdomain
2. Script sends beacon to `/c/e?s=<public_key>` (obfuscated endpoints)
3. CollectController validates payload, checks origin, resolves site by public key
4. Ingest.process enriches event (IP geo, UA parsing, session resolution)
5. IngestBuffer batches events, flushes to ClickHouse every 500ms
6. Dashboard LiveViews query ClickHouse events table directly

### Key Endpoints (obfuscated)
- `/assets/v1.js` — tracker script
- `/c/e` — event collection (POST)
- `/c/p` — noscript pixel (GET)
- `/c/i` — user identification
- `/c/x` — cross-domain token
- `/c/o` — opt-out cookie

### ClickHouse Schema
- Tables created by Elixir app on startup (`ensure_schema!` in ClickHouse module)
- Writer user needs INSERT + SELECT (materialized views require SELECT)
- Column naming: `ip_country` not `country`, `duration_s` not `duration`, `referrer_url` not `referrer`

## Development

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

Tests: `mix test` (102 tests, no ClickHouse needed)
Format: `mix format`
Compile check: `mix compile --warnings-as-errors`

## Deployment

Push to `main` triggers auto-deploy on Render. Docker build ~3-4 minutes.

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
- `RESEND_API_KEY` — for email (optional)

### Adding a new tracked site
1. Create site in Admin > Sites (domain = analytics subdomain, e.g. `b.example.com`)
2. Domain auto-registers on Render
3. Add DNS CNAME: `b.example.com` → `www.spectabas.com`
4. Install snippet on target site (from site settings page)
5. Parent domain (e.g. `www.example.com`) is auto-allowed for origin checks

### Diagnostic endpoint
`/health/diag` — shows ClickHouse connectivity, event counts, table list, write test, sample events

## Important Patterns

- **Auth**: Phoenix 1.8 scope-based. Access user via `socket.assigns.current_scope.user`
- **ClickHouse queries**: Always use `ClickHouse.param/1` for interpolated values
- **Column names**: Must exactly match ClickHouse table (see events table in clickhouse.ex)
- **Origin validation**: Auto-allows parent domain of analytics subdomain
- **Tracking subdomain plug**: Blocks all UI routes on analytics subdomains, only allows `/c/*`, `/assets/v1.js`, `/health`
- **Ad blocker evasion**: Script at `/assets/v1.js`, beacon uses public_key not domain, endpoints obfuscated as `/c/e`, `/c/p`
