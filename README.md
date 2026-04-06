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
- **Revenue Attribution** — sortable table with paid/organic split, three attribution models (first/last/any touch)
- **Revenue Cohorts** — LTV by first-purchase week heatmap
- **Buyer Patterns** — buyer vs non-buyer engagement comparison, page lift analysis
- **MRR & Subscriptions** — current MRR, plan breakdown, trend chart, cancellations, at-risk subscribers

### Ad Effectiveness
- **Visitor Quality Score** — engagement scoring (0-100) for ad traffic by platform/campaign
- **Time to Convert** — days/sessions between ad click and purchase
- **Ad Visitor Paths** — page sequences for ad visitors, conversion rate per path
- **Ad-to-Churn** — campaign-level churn correlation vs organic baseline
- **Organic Lift** — ad spend vs organic traffic correlation measurement

### Search & SEO
- **Search Keywords** — top queries, pages, position distribution, ranking changes
- **CTR Opportunities** — high-impression queries with below-average click-through rates
- **New & Lost Keywords** — keywords appearing or disappearing week-over-week
- **Position Distribution** — keyword count by ranking bracket (top 3, 4-10, 11-20, 20+)

### AI-Powered Insights
- **Weekly AI Analysis** — AI-generated prioritized action items from all data sources
- **On-demand insights** — "Generate Analysis" button on the Insights page
- **Multi-provider** — supports Anthropic (Claude), OpenAI, Google (Gemini)
- **Weekly AI email** — automated Monday morning digest with recommendations

### Integrations
- **Ad platforms** — connect via OAuth2 for ROAS tracking and click ID attribution
- **Payment providers** — import charges, refunds, subscriptions for revenue analytics
- **Search consoles** — import keyword rankings, clicks, impressions for SEO insights
- **Configurable sync frequency** — per-integration, from 5 minutes to 24 hours
- **Integration sync logging** — full event log with status, duration, and error details

### Platform
- **Multi-tenant** — account-based isolation with role hierarchy (platform_admin, superadmin, admin, analyst, viewer)
- **Automated Insights** — anomaly detection across traffic, SEO, revenue, ad spend, and churn
- **Email reports** — daily/weekly/monthly digests with traffic, keywords, revenue, and ad spend
- **SOC2 security** — password complexity, account lockout, idle session timeout, MFA enforcement, session management, audit logging
- **Two-factor auth** — TOTP and WebAuthn/passkeys with account-level enforcement
- **API keys** — granular scopes, site restrictions, optional expiry, access logging
- **Segmentation** — filter any report by any dimension with saved presets
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
mix test          # 676 tests, no ClickHouse needed
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
| `UTILITY_TOKEN` | Health/diagnostic endpoint auth |

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

Integrations -> OAuth2/API key connect -> Oban sync workers (per-integration frequency)
             -> ClickHouse ad_spend / search_console / ecommerce_events tables
             -> Revenue Attribution, Search Keywords, MRR pages

AI Analysis -> Anomaly detector + data aggregation
            -> Configured AI provider (Anthropic/OpenAI/Google)
            -> Insights page + weekly email
```

## License

Proprietary. All rights reserved.
