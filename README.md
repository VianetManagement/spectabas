# Spectabas

Privacy-first web analytics platform built with Elixir/Phoenix and ClickHouse.

## Features

- **Lightweight tracker** — 8KB JavaScript, ad-blocker resistant, GDPR-aware
- **Real-time analytics** — pageviews, visitors, sessions, bounce rate, duration
- **Visitor intent detection** — auto-classifies visitors as buying, researching, comparing, support, returning, browsing, or bot
- **Geographic insights** — country, state, city with interactive world map
- **Device & browser breakdown** — separate views for device type, browser, OS
- **Traffic sources** — referrer domains, UTM tracking, multi-channel attribution
- **Page flow analysis** — entry/exit pages, page transitions (came from / went to)
- **Site search tracking** — captures internal search queries from URL parameters
- **Outbound link tracking** — auto-tracks clicks on external links with destination domains and URLs
- **File download tracking** — auto-tracks downloads of PDF, ZIP, DOC, XLS, CSV, MP3, MP4, and more
- **Custom events browser** — browse all custom events fired via Spectabas.track()
- **Referrer spam filtering** — known spam domains automatically excluded from analytics
- **Cohort retention** — weekly retention grid showing returning visitor percentages
- **Visitor profiles** — individual session history, IP cross-referencing, full event timeline
- **Bot detection** — UA-based, client-side signals, datacenter IP, headless browser detection
- **IP enrichment** — DB-IP + MaxMind GeoLite2 for geo, timezone, ASN, EU flag
- **Campaign builder** — UTM URL generator with parameter guide
- **Segmentation** — filter any report by any dimension
- **Period comparison** — compare any metric to the equivalent previous period
- **Interactive charts** — Chart.js time-series, visitor map, bar charts
- **Custom date ranges** — presets (Today/24h/7d/30d/90d/12m) + custom picker, timezone-aware
- **Real User Monitoring** — Core Web Vitals (LCP, CLS, FID), page load timing, per-page speed indicators
- **Email reports** — daily/weekly/monthly analytics digests with period comparison, one-click unsubscribe

## Tech Stack

- **Elixir 1.17 / Phoenix 1.8** — LiveView for real-time dashboards
- **ClickHouse** — columnar analytics database for fast aggregations
- **PostgreSQL** — user accounts, sessions, site configuration
- **Chart.js** — interactive charts (vendored, no CDN)
- **Tailwind CSS 4** — utility-first styling
- **tzdata** — timezone database for site-local date boundaries
- **Render** — Docker-based deployment

## Quick Start

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

## Tests

```bash
mix test          # 390 tests, no ClickHouse needed
mix format        # code formatting
mix compile --warnings-as-errors  # strict compilation
```

## Deployment

Push to `main` auto-deploys on Render via Docker.

### Required Environment Variables

| Variable | Purpose |
|----------|---------|
| `DATABASE_URL` | PostgreSQL connection |
| `SECRET_KEY_BASE` | Phoenix secret |
| `PHX_HOST` | Production hostname |
| `CLICKHOUSE_URL` | ClickHouse HTTP endpoint |
| `CLICKHOUSE_DB` | Database name |
| `CLICKHOUSE_WRITER_USER` / `PASSWORD` | Write credentials |
| `CLICKHOUSE_READER_USER` / `PASSWORD` | Read credentials |

### Optional Environment Variables

| Variable | Purpose |
|----------|---------|
| `MAXMIND_LICENSE_KEY` | GeoLite2 timezone/EU enrichment |
| `RESEND_API_KEY` | Email delivery via Resend |
| `RENDER_API_KEY` | Auto-register custom domains |

## Adding a Tracked Site

1. Create site in Admin > Sites
2. Add DNS CNAME: `b.example.com` -> `www.spectabas.com`
3. Install the tracking snippet from site settings

## Architecture

```
Browser -> /assets/v1.js (tracker)
        -> /c/e (beacon POST)
        -> CollectController (validate, origin check)
        -> Ingest.process (UA parse, IP enrich, intent classify)
        -> IngestBuffer (batch, flush every 500ms)
        -> ClickHouse events table
        -> Dashboard LiveViews (real-time queries)
```

## License

Proprietary. All rights reserved.
