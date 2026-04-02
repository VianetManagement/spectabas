# Spectabas

Privacy-first web analytics platform built with Elixir/Phoenix and ClickHouse.

## Features

### Core Analytics
- **Lightweight tracker** — 8KB JavaScript, ad-blocker resistant (reverse proxy support), GDPR-aware
- **Real-time analytics** — pageviews, visitors, sessions, bounce rate, duration with 5-second refresh
- **Visitor intent detection** — auto-classifies visitors as buying, researching, comparing, support, returning, browsing, or bot
- **Geographic insights** — country, region, city drill-down with interactive visitor map
- **Device & browser breakdown** — device type, browser, OS, screen resolution
- **Traffic sources** — referrer domains, UTM tracking (all 5 dimensions), multi-channel attribution
- **Page flow analysis** — entry/exit pages, page transitions, visitor journeys
- **Site search tracking** — captures internal search queries from URL parameters
- **Outbound link & download tracking** — auto-tracked clicks and file downloads
- **Custom events** — Spectabas.track() API for any user interaction
- **Real User Monitoring** — Core Web Vitals (LCP, CLS, FID), page load timing, TTFB

### Conversions & Ecommerce
- **Goals & funnels** — pageview and custom event goals, multi-step funnel visualization with drop-off export
- **Ecommerce tracking** — revenue, orders, AOV, top products with categories, visitor-order linking
- **Revenue Attribution** — sortable table with paid/organic split, three attribution models (first/last/any touch), ad platform pills
- **Revenue Cohorts** — LTV by first-purchase week heatmap
- **Buyer Patterns** — buyer vs non-buyer engagement comparison, page lift analysis

### Ad Effectiveness (unique to Spectabas)
- **Visitor Quality Score** — engagement scoring (0-100) for ad traffic by platform/campaign
- **Time to Convert** — days/sessions between ad click and purchase with histogram
- **Ad Visitor Paths** — page sequences for ad visitors, conversion rate per path
- **Ad-to-Churn** — campaign-level churn correlation vs organic baseline
- **Organic Lift** — ad spend vs organic traffic correlation measurement

### Ad Platform Integrations
- **Google Ads, Bing Ads, Meta Ads** — OAuth2 connection with encrypted token storage (AES-256-GCM)
- **Click ID attribution** — automatic gclid/msclkid/fbclid capture for platform-level ROAS
- **Daily spend sync** — campaign spend, clicks, impressions every 6 hours
- **Google Ads account picker** — MCC/multi-account support
- **Sync Now button** — manual trigger from settings page

### Platform
- **Automated Insights** — anomaly detection for traffic, sources, revenue, ad traffic, and churn risk
- **Category landing pages** — hub pages with descriptions for all 38 dashboard pages
- **Breadcrumbs** — color-coded navigation trail on every page
- **Email reports** — daily/weekly/monthly digests with period comparison
- **Segmentation** — filter any report by any dimension with saved presets
- **Reverse proxy (data-proxy)** — serve tracker from main domain for ad blocker evasion
- **Browser fingerprinting** — canvas, WebGL, AudioContext, font probing for cookieless tracking
- **Cohort retention** — weekly retention grid
- **Visitor profiles** — session history, IP cross-referencing, fingerprint matching, click ID + UTM data
- **Bot detection** — UA-based, navigator.webdriver, datacenter IP, headless browser
- **API keys** — granular scopes, site restrictions, optional expiry, access logging
- **Two-factor auth** — TOTP and WebAuthn/passkeys, admin force 2FA
- **Spam filtering** — auto-detection + manual blocklist

## Tech Stack

- **Elixir 1.17 / Phoenix 1.8** — LiveView for real-time dashboards
- **ClickHouse** — columnar analytics database for fast aggregations
- **PostgreSQL** — user accounts, sessions, site configuration
- **Chart.js** — interactive charts (vendored, no CDN)
- **Tailwind CSS 4** — utility-first styling
- **tzdata** — timezone database for site-local date boundaries
- **wax_** — WebAuthn/passkey 2FA support
- **Render** — Docker-based deployment (Ohio region)

## Quick Start

```bash
mix deps.get
mix ecto.setup
mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

## Tests

```bash
mix test          # 560 tests, no ClickHouse needed
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

### Proxy Mode (ad blocker evasion)

```html
<script defer data-id="YOUR_KEY"
  data-proxy="https://www.example.com/t"
  src="https://www.example.com/t/v1.js"></script>
```

Requires a reverse proxy plug on your Phoenix app — see docs after login.

## Architecture

```
Browser -> /assets/v1.js (tracker)
        -> /c/e (beacon POST with click IDs, UTMs)
        -> CollectController (validate, origin check)
        -> Ingest.process (UA parse, IP enrich, click ID extract, intent classify)
        -> IngestBuffer (batch 500, async flush)
        -> ClickHouse events table
        -> Dashboard LiveViews (real-time queries)

Ad Platforms -> OAuth2 connect -> AdSpendSync (Oban, every 6h)
            -> ClickHouse ad_spend table
            -> Revenue Attribution (ROAS, per-platform breakdown)
```

## License

Proprietary. All rights reserved.
