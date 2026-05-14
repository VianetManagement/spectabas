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
- **API keys**: Scopes (`read:stats`, `read:visitors`, `write:events`, `write:identify`, `write:whitelist`, `admin:sites`), site restrictions, optional expiry. All calls logged (30-day retention, `/admin/api-logs`).

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
- **Enrichment fields on grouped queries MUST use `anyIf(field, event_type = 'pageview')`** (and `argMaxIf` / `argMinIf` likewise). The fast ingest path leaves `ip_*`, `browser`, `os`, `device_type`, `screen_*`, `user_agent`, `browser_fingerprint`, `visitor_intent`, `referrer_domain`, etc. empty on custom and duration events. Without the filter, `any()` can return an empty-string row from an auto-click `_click` event and the dashboard renders blanks (this happened in `visitor_profile`, `visitor_ips`, `realtime_visitors_grouped`, and `ip_details` after auto-click went live). Applies project-wide, not just to scraper queries.

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

### Scraper Labels (Stage 1: report; Stage 2-3: not yet built)
Append-only `scraper_labels` table captures every Mark as Scraper / Whitelist / Unflag / auto-flag / auto-downgrade with the visitor's signal vector at the moment of the click. `Spectabas.ScraperLabels.record/1` (best-effort, swallows errors). **Does not change current detection.** Sources have confidence weights for future training: human clicks 1.0, auto-fired flags 0.3 (circular). Full design + training plan in `docs/scraper-labels.md`. Don't backfill — signal vector at the time of pre-existing flags can't be reconstructed accurately.

**Stage 1 (v6.10.27): label correlation report** at `/admin/scraper-labels`. `ScraperLabels.signal_correlation_report/1` reads high-confidence labels (`source_weight >= 0.7` — humans + ecommerce purchases) and surfaces: counts by source, per-signal P(signal|scraper) vs P(signal|not_scraper) + heuristic verdict (`:underweighted` / `:overweighted` / `:weak_signal`), false-positive list (score ≥ 85 + manually whitelisted), false-negative list (score < 40 + manually flagged). No model fitting — eyeball the report to guide hand-tuning of weights in `ScraperDetector.@default_weights`. Stage 2 (AI-prompt enrichment with label correlations) and Stage 3 (logistic regression once ≥200 labels/site) deferred per `docs/scraper-labels.md` training plan.

### Scraper Detection
Weighted-signal scoring (15 signals, cap 100). Tiers from `ScraperDetector.verdict/1` (single source of truth — used by the worker tier-escalation gate, the visitor profile badges, and the ScrapersLive score colors): `:watching` (40-69), `:suspicious` (70-84), `:certain` (85+), `:normal` (<40). The four scoring queries — `scraper_score_for_visitor/3`, `scraper_candidates/4`, `scraper_candidates_system/2`, `scraper_scores_for_visitors/3` — all share the private `scraper_profile_sql/2` builder and `score_row/2` row-scorer so they can't drift in their SELECT shape. The webhook worker (`Workers.ScraperWebhookScan`) runs every 15min over a 24h window AND daily at 03:00 UTC over a 168h (7d) window — the wider sweep catches slow scrapers active across days. Worker always persists `scraper_last_scan_score` + `scraper_last_scan_at` to PG on every candidate scan (separate column from `scraper_webhook_score` so the tier-escalation gate still uses last-webhook score, not last-scan score). Uses `uniqIf(url_path)` not `countIf`. VPN providers suppress `datacenter_asn` and `spoofed_mobile_ua` signals — `known_vpn_provider?` trims whitespace, `is_vpn` checks `in [true, 1, "1"]`. `ScraperDetector` is pure/stateless. Webhooks fire at 40+ via `ScraperWebhookScan` (15min Oban), payload includes `sab_cookie`. ASN management: `ASNDiscovery` weekly (Sunday 04:00 UTC), `ASNBlocklist` ETS (~900 ASNs). **IMPORTANT**: Scraper queries MUST use `argMaxIf(field, timestamp, event_type='pageview')` not `argMax` — lightweight ingest path leaves enrichment fields empty on custom/duration events. Manual "Mark as Scraper" button on visitor profiles sets score 100 + sends webhook + sets `scraper_manual_flag = true`. Manually-flagged visitors are excluded from the 15-min downgrade scan in `check_downgrades` so the sticky manual flag survives even when their automatic score drops below the watching threshold. The "Marked as Scraper" badge on the visitor profile checks `scraper_manual_flag OR scraper_webhook_score == 100`. **Whitelist** is the inverse: `scraper_whitelisted` boolean on visitors — `process_candidate` short-circuits on whitelisted visitors so they never get auto-flagged regardless of score. "Unflag" only clears the current flag (subject to re-flag on next run); "Whitelist" is the permanent action. Whitelist follows the user across cookies/devices via email: `Visitors.identify/4` inherits `scraper_whitelisted = true` if any other visitor on the same site shares that email; the profile Whitelist button calls `Visitors.propagate_whitelist_by_email/3` to fan out to all sibling records on the site at toggle time.

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
- **Heroicons setup**: three pieces have to be in place. (1) `mix.exs` declares `:heroicons` as a sparse git dep so `deps/heroicons/optimized/24/outline/*.svg` exists during the production build (without it, `mix tailwind ... --minify` crashes with ENOENT scandir). (2) `assets/css/app.css` activates the plugin via `@plugin "../vendor/heroicons"` so the per-icon classes get generated. (3) Same file adds `mask-size: contain` for `[class*="hero-"]` so icons sized smaller than the SVG's natural size (e.g. `w-3 h-3` on a 24px outline) don't only show a corner of the mask. Don't remove any of the three.
- **Changelog**: v6.10.30 at `/admin/changelog`. Updated every push. Bumping a version means adding a new entry to the top of `ChangelogLive.entries/0` + updating this line. The Slack deploy notifier reads `ChangelogLive.current_version/0` at runtime (which returns the first entry's version), so the changelog is the single source of truth — no separate version constant to keep in sync.
- **Suggested Funnels ranking**: `Analytics.suggested_funnels_from_goals/2` and `_from_ecommerce/1` now rank by `log(1 + converters) * (converters / non_converters)` — a lift score combining volume with conversion-vs-non-conversion signal. Paths in `@funnel_path_denylist` (homepage, sign-in/sign-out, login/signup, password reset, /auth/*, /api/*) are stripped from candidate sequences before grouping. Query strings stripped via `splitByChar('?', path)[1]`. Add new noise paths to the denylist module attribute if they surface. Snapshotted as `suggested_funnels` kind in `dashboard_snapshots` (refreshed hourly).
- **Goal Detail snapshot**: Per-goal detail data (stats / timeseries / sources / pages / devices / geo / recent_completers / click_element_info + email map) is stored as `goal_detail:<goal_id>` kind in `dashboard_snapshots`. Refreshed at the end of `DashboardSnapshot`'s hourly run (per-site, iterates goals). GoalDetailLive reads synchronously for default range 30d; 7d/90d fall back to live CH. `Goals.delete_goal/2` cleans up the snapshot row.
- **ClickHouse 30s HTTP timeout**: `Spectabas.ClickHouse` bakes `receive_timeout: 30_000` into Req's default opts. The SQL `SETTINGS max_execution_time = N` is **not enough** for queries that can take >30s — the HTTP client disconnects before CH finishes and the caller silently sees `{:error, _}` (which often falls through to zero/empty handlers, hiding the bug). For heavy queries pass `receive_timeout: N` (in ms) to `ClickHouse.query/2` matching the SQL setting. Examples: `do_funnel_stats` (200_000), `ClickElementSnapshot` (260_000), `suggested_funnels_from_goals` (150_000), the 8 `goal_detail*` queries (90_000, but the `goal_detail_stats` total_visitors sub-query is at 200_000 since v6.10.17), the 2 `do_goal_completions` queries that back the Goals landing-page table (200_000), and all 11 queries in `Spectabas.SearchKeywords` (200_000, via the `ch_query/1` private helper that also appends `SETTINGS max_execution_time = 180`). Rule of thumb: if a query touches `JSONExtract*`, FINALs over a multi-million-row table, or scans more than a few days of events, default to 200_000ms — these are 10-100x slower than column reads and time out unpredictably under load.
- **AI weekly insights worker**: `Workers.AIWeeklyEmail` is now per-site fan-out (meta-job @ Monday 9am UTC enqueues one per-site job for every site with `auto_generate` on). Worker timeout 600s; `AI.Completion.@timeout` 300s for the Anthropic HTTP call. Markdown rendering for the email body lives in `Spectabas.AI.MarkdownEmail` — extend that module for any new markdown feature, don't inline new renderers in the worker.
- **Snapshot diagnostic endpoints**: see `/oban-admin?action=snapshot_status / snapshot_site_status&site_id=N / trigger_snapshots&site_id=N / click_element_probe / funnel_summaries_probe / funnel_worker_dryrun / funnel_worker_run / funnel_stats_dump / ai_insights_status / trigger_ai_weekly / dashboard_snapshot_dump / goal_stats_dump / goal_completions_probe / backfill_click_element_cols / click_element_backfill_status`. Defined in `health_controller.ex`. All gated on `UTILITY_TOKEN`.
- **Click-element materialized columns (`element_text`, `element_id`)**: added v6.10.23, swapped into call sites v6.10.26. `events.element_text = JSONExtractString(properties, '_text')` and `events.element_id = JSONExtractString(properties, '_id')` populate automatically at INSERT time via the MATERIALIZED expression in the schema. Bloom-filter skip indexes `idx_element_text` and `idx_element_id`. **Use these columns directly** in any new query that filters or groups on `_text` / `_id` — they're 10-100x faster than the JSON parse. _tag, _classes, _href remain on JSONExtractString since they're SELECT-only. **Fresh-clone / new-site setup**: `ensure_schema!` adds the columns idempotently on boot. Backfill of new historical data: `/oban-admin?action=backfill_click_element_cols&token=...` enqueues `ALTER TABLE events MATERIALIZE COLUMN`, poll status with `click_element_backfill_status` until `is_done=1`. NEVER swap call sites for these columns before backfill completes on the data range you're querying — the filter returns `''` for un-materialized rows and the queries silently miss them.
- **Snapshot pattern for slow dashboard tables**: Four kinds of hourly Postgres snapshots back the most-loaded dashboard surfaces.
  - **Per-entity tables** (one row per thing): `click_element_stats` (`:20`), `goal_stats` (`:25`), `funnel_stats` (`:30`). Workers: `ClickElementSnapshot`, `GoalStatsSnapshot`, `FunnelStatsSnapshot`. `Goals.create_goal/2` and `create_funnel/2` enqueue an immediate per-site snapshot.
  - **Per-page JSONB store** (`dashboard_snapshots`, keyed by `(site_id, kind)`): `outbound_links`, `downloads`, `events`, `site_search`, `bot_traffic`, `acquisition`, `ecommerce`, `pages`, `entry_exit`, `geography`, `devices`, `campaigns` (default 30d), `performance`, `search_keywords` (default 30d + all sources + total_clicks-desc sort), `revenue_attribution` (default 30d + group_by=source + touch=last), `mrr` (no user filters — all-time + 30d trend). Worker: `DashboardSnapshot` at `:35`. Pages render from PG only on their **default date range** (and for acquisition, only when no channel is selected; for site_search, only when no param filter is active; for geography, only when no country drill-down; for search_keywords, only at the default sort/source; for revenue_attribution, only at group_by=source + touch=last); non-default config falls back to live CH via the existing `load_data` path. Use `Spectabas.DashboardSnapshots.with_fallback/5` for the simple list pages and `fetch/2` for multi-widget pages. Search Keywords queries live in `Spectabas.SearchKeywords`, MRR queries in `Spectabas.MRR` — context modules shared between the worker and LiveView.
  - All workers fan out per-site jobs on the `:maintenance` queue. **Don't add new dashboard code paths that re-query CH for these snapshotted views** — extend the worker instead.
  - `goal_stats` / `funnel_stats` use `_system` Analytics variants (skip auth). `dashboard_snapshots` worker uses the existing public Analytics API with a synthetic `%Accounts.User{role: :platform_admin}` — `can_access_site?` returns true for that role, so no new variants needed.

### Server-Side Ad Conversion Tracking
Full pipeline at `/dashboard/sites/:id/conversions`. `Spectabas.Conversions` context with `conversion_actions` (per-site config) + `conversions` (one row per detected event) Postgres tables. Three detectors run every 15 min via `Workers.ConversionDetector`: Stripe payments → purchase, URL pattern → pageview match, click element → button match. First-click resolver walks events backward in 90d window. `Workers.ConversionUploader` runs hourly, pushes to **Google Data Manager API** (`/v1/events:ingest`, requires `datamanager` OAuth scope on Google Ads connection — existing connections must reconnect) and **Microsoft Ads Bulk API**. Tracker captures gclid/**wbraid/gbraid**/msclkid into `_sab_click_id` sessionStorage. Quality gate via `max_scraper_score` (default 40) skips bot-scoring visitors so Smart Bidding doesn't learn bot patterns. Idempotent via `(site_id, conversion_action_id, dedup_key)` unique index. Full design in `docs/conversions.md`.
