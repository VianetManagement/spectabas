defmodule SpectabasWeb.Admin.ChangelogLive do
  use SpectabasWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Changelog")
     |> assign(:entries, entries())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
          &larr; Admin Dashboard
        </.link>
        <h1 class="text-2xl font-bold text-gray-900 mt-2">Changelog</h1>
        <p class="text-sm text-gray-500 mt-1">Recent changes and new features</p>
      </div>

      <div class="space-y-10">
        <div :for={{version, utc_iso, items} <- @entries}>
          <h2 class="text-lg font-semibold text-gray-900 border-b border-gray-200 pb-2 mb-4">
            {version} —
            <span
              phx-hook="LocalTime"
              id={"ts-#{version}"}
              data-utc={utc_iso}
              class="font-normal text-gray-600"
            >
              {utc_iso}
            </span>
          </h2>
          <ul class="space-y-3">
            <li :for={item <- items} class="flex gap-3">
              <span class="mt-1.5 flex-shrink-0 h-2 w-2 rounded-full bg-indigo-500"></span>
              <div>
                <span class="font-medium text-gray-900">{item.title}</span>
                <span :if={item.description} class="text-gray-600">
                  &mdash; {item.description}
                </span>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  def entries do
    [
      {"v5.82.0", "2026-04-19T12:00:00Z",
       [
         %{
           title:
             "Enhancement: AI insights now include goals, funnels, click elements, and conversion paths",
           description:
             "The weekly AI analysis prompt now sends 4 new data sections: goal performance (completions + conversion rates, 7d vs prior), funnel drop-off analysis (biggest bottleneck per funnel), top clicked elements (7d, 5+ clicks), and auto-detected conversion paths. System prompt updated with a Conversion & Goals section. Word limit raised from 800 to 1000."
         }
       ]},
      {"v5.81.0", "2026-04-19T11:00:00Z",
       [
         %{
           title: "Feature: Auto-suggested funnels from conversion paths",
           description:
             "The Funnels page now shows suggested funnels mined from real visitor data. Identifies converting visitors (goal completers or purchasers), extracts their last 2-5 page sequences before conversion, groups by common paths, and ranks by converter volume. One-click 'Create' button turns any suggestion into a funnel. Requires at least 3 converters sharing a path to suggest."
         }
       ]},
      {"v5.80.0", "2026-04-19T10:00:00Z",
       [
         %{
           title: "Fix: Funnel/goal detail date ranges + icon-only button detection",
           description:
             "Fixed ensure_date_range crashing on string periods ('7d', '30d', '90d') — both funnel and goal detail pages showed empty data because the rescue silently swallowed the FunctionClauseError. Icon-only buttons (no text, no ID, no aria-label) are now detected by the tracker via child element icon classes (hero-*, icon-*, fa-*, lucide-*) and shown as e.g. [hero-paper-airplane-solid] in Click Elements."
         }
       ]},
      {"v5.79.0", "2026-04-19T08:00:00Z",
       [
         %{
           title: "Fix: Funnel data now displays + edit/delete funnels",
           description:
             "Fixed funnel_stats using wrong step key names ('path'/'name' vs 'value') — all steps matched 1=0 and returned no data. Now uses shared build_funnel_conditions with backward compatibility for both key formats. Added funnel editing: rename, add/remove/reorder steps, change step types. Delete button with confirmation. Edit form uses the same proper <form phx-change> pattern as creation."
         }
       ]},
      {"v5.78.0", "2026-04-19T07:00:00Z",
       [
         %{
           title: "Feature: Funnel detail pages",
           description:
             "Each funnel is now clickable — opens a dedicated detail page with summary cards (entered, completed, completion rate, total drop-off), visual funnel with progress bars and drop-off indicators between steps, step breakdown table with visitor counts and drop-off percentages, date range selector (7d/30d/90d), and CSV export of abandoned visitors at each step. Goal-type steps resolve to goal names."
         }
       ]},
      {"v5.77.0", "2026-04-19T06:00:00Z",
       [
         %{
           title: "Fix: Weekly email reports only send on Mondays, monthly on 1st",
           description:
             "Weekly email reports were sending on the first hour of any new ISO week, which could be any day. Added day-of-week gating: weekly reports only dispatch on Monday, monthly reports only on the 1st of the month. Daily reports unchanged."
         }
       ]},
      {"v5.76.0", "2026-04-19T05:00:00Z",
       [
         %{
           title:
             "Fix: Funnel form — goal dropdown, sortable goals, click element dedup, search/pagination",
           description:
             "Funnel creation form rewritten to use proper <form phx-change> — selects now work correctly. Goal step type shows a dropdown of existing goals. Removed Click Element as a direct funnel step (use Goal steps for click tracking). Goals page has sortable columns. Click Elements page has live search + pagination (20/page). Click element dedup fixed — GROUP BY no longer splits on href/classes. Multiple number formatting fixes across dashboard."
         }
       ]},
      {"v5.75.0", "2026-04-19T03:00:00Z",
       [
         %{
           title: "Feature: Goal detail pages + Click Element registry",
           description:
             "Each goal is now clickable — opens a dedicated detail page with completion trend chart, stat cards (total/unique/conversion rate/avg per visitor), top sources, top pages, device and geographic breakdown, and recent completers with email lookup. Click element goals also show element metadata (tag, text, classes, pages). New Click Elements page under Conversions: browse all auto-detected buttons/links with click counts, assign friendly names, see which goals reference each element, filter by tag type, sort by clicks/visitors, and create goals with one click."
         }
       ]},
      {"v5.74.0", "2026-04-19T02:00:00Z",
       [
         %{
           title: "Feature: Click element steps in funnels + UI consistency pass",
           description:
             "Funnel creation now supports click element steps alongside pageview and custom event. Detected click elements show as pills below the steps list — click to add as a step. Also standardized all form inputs and dropdowns to rounded-lg across 12 dashboard pages for visual consistency."
         }
       ]},
      {"v5.73.0", "2026-04-19T01:00:00Z",
       [
         %{
           title: "Fix: Comma formatting on all dashboard numbers + click element empty state",
           description:
             "Fixed 18 places across 8 dashboard pages where visitor/session/order counts displayed without comma separators (e.g. 12345 instead of 12,345). Affected: Goals completions, Churn Risk stats, Campaigns counts, Ecommerce order counts, Organic Lift visitor counts, Revenue Attribution orders, Scrapers IP counts. Also added helpful empty state message for click element discovery explaining that elements appear after visitors click."
         }
       ]},
      {"v5.72.0", "2026-04-18T23:00:00Z",
       [
         %{
           title: "Feature: AI help chatbot on dashboard",
           description:
             "Floating chat widget on all dashboard pages — ask questions about Spectabas features, setup, goals, integrations, and more. Powered by Claude Haiku via platform-level HELP_AI_API_KEY. Multi-turn conversation with markdown rendering, auto-scroll, and bouncing loading dots. Only appears when the env var is set."
         }
       ]},
      {"v5.71.0", "2026-04-18T22:00:00Z",
       [
         %{
           title: "Feature: Click element goals with auto-detection",
           description:
             "New goal type: track button and link clicks without custom code. The tracker auto-captures clicks on buttons, internal links, form submits, and role=\"button\" elements — sending element text, ID, classes, and tag as event properties. Create goals by element ID (#signup-btn) or visible text (text:Add to Cart, wildcards supported). The goal creation form shows elements detected on your site in the last 30 days, click to auto-populate. Works in funnels too."
         },
         %{
           title: "Fix: Goal creation form was silently failing",
           description:
             "Goals.create_goal used an atom key (:site_id) in a string-keyed map. Ecto's cast detected the atom first and ignored all string keys, so name/type/path were never cast — validation silently failed with no error display. Fixed by using string key. Also fixed: delete_goal handler passed wrong arguments (goal struct + user instead of site + id), and added form validation error display."
         }
       ]},
      {"v5.70.0", "2026-04-18T20:00:00Z",
       [
         %{
           title: "Fix: Privacy relay ASNs in datacenter blocklist no longer flag real users",
           description:
             "Akamai ASNs (20940, 36183, 63949) are in both the datacenter blocklist and the privacy relay list. The suppression logic now checks both — if an ASN is a known privacy relay, VPN suppression applies even if the ASN is also in the datacenter list. Fixes iCloud Private Relay users being scored 70+ instead of ~10."
         }
       ]},
      {"v5.67.0", "2026-04-18T17:00:00Z",
       [
         %{
           title: "Feature: Self-managing ASN discovery system with admin dashboard",
           description:
             "Weekly Oban worker scans 30 days of traffic to find unclassified hosting ASNs using behavioral scoring (engagement, bounce rate, org name keywords). High-confidence ASNs auto-added to datacenter blocklist with automatic ClickHouse backfill. Lower-confidence candidates logged for review. Admin page at /admin/asn-management with full audit trail, manual add/approve/deactivate, and evidence display."
         }
       ]},
      {"v5.66.0", "2026-04-18T16:00:00Z",
       [
         %{
           title: "Enhancement: Scraper detector now uses full ~900-entry ASN blocklist",
           description:
             "The datacenter_asn signal now uses the ASNBlocklist ETS table (~900 datacenter ASNs from priv/asn_lists/) instead of a hardcoded 21-entry list. Automatically stays current when blocklist files are updated. Falls back to the static list in tests."
         }
       ]},
      {"v5.65.0", "2026-04-18T15:30:00Z",
       [
         %{
           title: "Fix: Smart VPN suppression — distinguishes consumer VPNs from datacenter VPNs",
           description:
             "VPN suppression for datacenter/spoofed_mobile signals now checks both is_vpn flag AND whether the ASN is a known datacenter. VPN on OVH/Contabo (PublicVpnConfigs) still fires datacenter signal. VPN on Akamai/Fastly/Cloudflare (iCloud Private Relay) is correctly suppressed. Handles stale ip_is_datacenter flags from pre-Akamai-fix events."
         }
       ]},
      {"v5.64.0", "2026-04-18T15:00:00Z",
       [
         %{
           title: "Tune: Pageview thresholds recalibrated from 642k visitor analysis",
           description:
             "Removed 20-page and 50-page scraper signals (92% and 90% residential). New thresholds: 100+ (+10), 200+ (+15), 500+ (+20), 1000+ (+50). Pageview signals alone can no longer push a visitor past the watching threshold without other signals combining."
         }
       ]},
      {"v5.63.0", "2026-04-18T14:00:00Z",
       [
         %{
           title: "Fix: iCloud Private Relay users no longer flagged as scrapers",
           description:
             "IP rotation signal now suppressed for VPN/privacy relay visitors (they rotate IPs by design). Removed 0x0 from suspicious resolution list (iOS in-app webviews, not headless browsers). Also passes is_vpn flag to scraper profile for accurate VPN detection."
         }
       ]},
      {"v5.62.0", "2026-04-18T12:00:00Z",
       [
         %{
           title: "Feature: Automatic scraper webhook downgrade notifications",
           description:
             "When signal weights change or data is corrected, previously-flagged visitors are automatically re-scored every 15 minutes. If their score drops to a lower tier, a downgrade webhook is sent. Dropping below score 40 sends a full deactivation. Also fixed: datacenter ASNs now always set ip_is_datacenter=1 even when VPN is detected (scrapers using open VPN configs on OVH/Contabo were evading detection), and scraper scores now use argMax for deterministic values across time windows."
         }
       ]},
      {"v5.61.0", "2026-04-18T10:00:00Z",
       [
         %{
           title: "Enhancement: AI calibration now covers all 15 signals with real data",
           description:
             "Added Chrome version distribution and content crawl pattern analysis to the calibration baseline. All 15 scraper signals now have data for AI calibration — no more blind recommendations. Also: Akamai AS36183/200005/32787 added to privacy relay list (was flagging iCloud Private Relay users as scrapers), and unflag button on visitor profile page."
         }
       ]},
      {"v5.60.0", "2026-04-18T02:30:00Z",
       [
         %{
           title: "Feature: Three new scraper detection signals from real traffic analysis",
           description:
             "Mined 21M+ ClickHouse events to identify bot patterns. Added: square_resolution (+15, no real screen is square — excludes Facebook/social crawlers), stale_browser (+15, Chrome < v100 is 4+ years old), resolution_device_mismatch (+10, smartphone UA + desktop resolution). Immediately catches Xairnet bot farm (7k+ fake visitors/month with 1280x1024 + Chrome 58). Suspicious resolution list trimmed to headless-only (800x600, 1024x768, 0x0)."
         }
       ]},
      {"v5.59.0", "2026-04-18T02:00:00Z",
       [
         %{
           title: "Feature: Admin ClickHouse query endpoint for diagnostics",
           description:
             "POST /api/admin/query accepts read-only SELECT queries authenticated via UTILITY_TOKEN Bearer header. Returns JSON rows. Used for scraper signal analysis and ad-hoc diagnostics."
         },
         %{
           title: "Fix: AI calibration session duration was always 0",
           description:
             "Duration data lives on event_type='duration' rows, not pageviews. Fixed calibration query to use maxIf(duration_s, event_type='duration'). Also added screen resolution distribution as calibration input, and trimmed suspicious resolutions to only truly headless defaults (800x600, 1024x768, 0x0)."
         }
       ]},
      {"v5.58.0", "2026-04-18T01:30:00Z",
       [
         %{
           title: "Fix: Visitor map disappearing on dashboard after deferred stats load",
           description:
             "Conditional :if blocks (Visitor Intent, Identified Users) were adding/removing DOM elements when deferred results arrived, causing morphdom to lose track of the phx-update=\"ignore\" map element. Switched to CSS hidden class so the DOM structure stays stable. Also fixed calibration tab template crash when AI reasoning is a map."
         }
       ]},
      {"v5.57.0", "2026-04-17T20:30:00Z",
       [
         %{
           title: "Enhancement: Deep AI scraper calibration with forensic traffic analysis",
           description:
             "AI calibration now gathers 10 data dimensions (pageview distribution, session duration, device breakdown, top ASNs, bounce rate by network, VPN providers, IP rotation, pageview thresholds) and sends a detailed forensic prompt. The AI analyzes each signal individually with per-signal confidence ratings, sample scenarios, and false-positive risk assessment."
         }
       ]},
      {"v5.56.0", "2026-04-17T12:00:00Z",
       [
         %{
           title: "Fix: Scraper AI calibration runs as background job (Oban)",
           description:
             "AI calibration now runs as an Oban background job instead of an unlinked Task. Results persist to the database and appear even if you navigate away from the page. PubSub pushes live updates if you stay on the Scrapers page."
         }
       ]},
      {"v5.55.0", "2026-04-18T08:00:00Z",
       [
         %{
           title:
             "Feat: Scraper detection overhaul — VPN/privacy relay protection, AI calibration, extreme pageviews",
           description:
             "Major scraper detection improvements: VPN provider detection via ipapi.is MMDB (NordVPN, Mullvad, etc.). Privacy relay ASNs (Akamai, Fastly, Cloudflare) suppress datacenter signal and clear DC flag. New extreme_pageviews_1000 tier (+50) for 1000+ unique pages — catches residential scrapers. Rebalanced weights: datacenter_asn +40, no_referrer +10, escalating pageview tiers. AI-powered per-site score calibration with approve/reject workflow. VPN backfill job for historical data. GeoIP admin page with per-database re-download buttons."
         }
       ]},
      {"v5.54.0", "2026-04-18T07:00:00Z",
       [
         %{
           title: "Feat: AI-powered scraper score calibration with per-site weight overrides",
           description:
             "New Calibration tab on the Scrapers page. Click 'Run AI Calibration' to analyze your site's 30-day visitor baseline (pageview distribution, network breakdown, referrer mix) and get AI-recommended weight adjustments. Review recommendations with Approve/Reject buttons. Approved weights are stored per-site and used automatically for all scraper scoring. Reset to Defaults button to clear overrides."
         }
       ]},
      {"v5.53.0", "2026-04-18T06:00:00Z",
       [
         %{
           title: "Tune: Scraper scoring rebalanced with escalating pageview tiers",
           description:
             "datacenter_asn +35→+40, no_referrer +5→+10. Pageviews now escalate: 20+ unique pages (+10), 50+ (+15), 100+ (+20), 200+ (+25). The visitor at score 50 would now score 65. Puppies-side tarpit threshold should be lowered from 70 to 60 to match."
         },
         %{
           title: "Fix: DB-IP download — use raw: true to prevent double-decompression",
           description:
             "Req auto-decompresses gzip responses. DB-IP downloads (.mmdb.gz) were getting gunzipped by Req and then gunzipped again by our code, causing a crash. Added raw: true and increased timeout to 180s."
         },
         %{
           title: "Fix: ipapi VPN download — added per-file extraction logging",
           description:
             "Added detailed logging for each file extracted from the ipapi.is tar.gz archive to diagnose the missing interpolated-vpn.mmdb issue."
         }
       ]},
      {"v5.52.0", "2026-04-18T05:00:00Z",
       [
         %{
           title: "Feat: Unified GeoIP database management with VPN pills",
           description:
             "All databases (DB-IP, MaxMind, ipapi.is VPN) now auto-download at boot from their APIs and refresh weekly (Monday 06:00 UTC). Admin page at /admin/geoip with per-database re-download buttons and download history. GeoIP link added to admin dashboard. VPN provider shown on visitor profile (e.g. 'VPN (NordVPN)') and realtime page (purple pill). Scraper score on visitor profile now uses last 7 days to match Scrapers page."
         }
       ]},
      {"v5.51.0", "2026-04-18T04:00:00Z",
       [
         %{
           title: "Feat: Auto-download GeoIP databases with admin status page",
           description:
             "All external IP databases (DB-IP, MaxMind, ipapi.is VPN) now auto-download on boot and refresh on the 1st/15th of each month. Set IPAPI_API_KEY env var for VPN databases. New admin page at /admin/geoip shows current database status (loaded/not loaded), download history with timestamps, file sizes, durations, and errors. Refresh Now button triggers an immediate download."
         }
       ]},
      {"v5.50.0", "2026-04-18T03:00:00Z",
       [
         %{
           title: "Feat: Three-tier scraper scoring aligned with webhook recipients",
           description:
             "Scraper scores now drive a three-tier response: Certain (85+, full countermeasures), Suspicious (70-84, tarpit only), Watching (40-69, log and observe). Webhook send threshold lowered from 60 to 40 for watching-tier visibility. Webhooks re-fire on tier escalation (watching → suspicious → certain). activation_delay_hours always 0 — recipient manages timing. Documentation updated with tier table, VPN safety info, and signal weights."
         }
       ]},
      {"v5.49.0", "2026-04-18T02:00:00Z",
       [
         %{
           title: "Feat: VPN provider detection — suppresses false-positive scraper signals",
           description:
             "Integrated ipapi.is IP to VPN database (enumerated + interpolated MMDB). Visitors on known consumer VPNs (NordVPN, Mullvad, ProtonVPN, etc.) no longer trigger the datacenter_asn (+35) or spoofed_mobile_ua (+20) scraper signals. New ip_vpn_provider column in ClickHouse events. Health diagnostic endpoint shows VPN database status. Set IPAPI_VPN_DIR env var to the directory containing the MMDB files."
         }
       ]},
      {"v5.48.1", "2026-04-18T01:00:00Z",
       [
         %{
           title: "Feat: Page Load Timing over time chart on Performance page",
           description:
             "New line chart showing TTFB, First Paint, DOM Ready, and Full Load (all in ms) trended daily. Appears after the Page Load Timing summary cards, before Performance by Device."
         }
       ]},
      {"v5.48.0", "2026-04-18T00:00:00Z",
       [
         %{
           title: "Feat: Sortable columns on Scraper Detection page",
           description:
             "Score, Pageviews, IPs, and Last Seen columns are now sortable (click header to toggle asc/desc). Default sort: score descending."
         },
         %{
           title: "Feat: Visitor profile opens in new window from Scrapers page",
           description:
             "The 'Full visitor profile' button in the scraper detail modal now opens in a new browser tab. Webhook log visitor links also open in new tabs."
         },
         %{
           title: "Feat: Scraper score pill on Realtime page",
           description:
             "Active visitors who have been flagged via scraper webhook now show a color-coded 'Scraper N' pill next to their visitor ID on the Realtime page. Red for certain (85+), amber for suspicious (60-84)."
         }
       ]},
      {"v5.47.0", "2026-04-17T23:00:00Z",
       [
         %{
           title: "Feat: Core Web Vitals over time chart on Performance page",
           description:
             "New dual-axis line chart showing LCP, FID (left axis, ms) and CLS (right axis, dashed line) trended daily over the selected date range. Appears between the CWV summary cards and Page Load Timing section. Uses race-free data-chart attribute pattern for initial render."
         }
       ]},
      {"v5.46.4", "2026-04-17T22:00:00Z",
       [
         %{
           title: "Fix: Visitor map renders world outline even with no data",
           description:
             "BubbleMap chart hook bailed out on empty data, preventing the world map background from rendering. Now always initializes the chart so the map outline appears even when ClickHouse is unavailable or returns no location data."
         }
       ]},
      {"v5.46.3", "2026-04-17T21:00:00Z",
       [
         %{
           title: "Perf: All dashboard pages now load instantly with deferred data",
           description:
             "Converted Pages, Geography, Devices, Network, and Ecommerce from synchronous to deferred loading. All 39 dashboard pages now render instantly with a loading spinner, then fill in data asynchronously. No more blank screens while ClickHouse queries run."
         }
       ]},
      {"v5.46.2", "2026-04-17T20:00:00Z",
       [
         %{
           title: "Fix: ClickHouse memory limits to prevent OOM crash",
           description:
             "Per-query memory reduced from 2GB to 800MB. Server memory cap lowered from 75% to 60% of RAM. Added max_bytes_before_external_group_by (400MB) to spill heavy GROUP BY to disk. Query timeout set to 120s. ClickHouse connection pool reduced from 100 to 10. Rollup INSERT queries for page and geo tables capped at 500MB with 250MB external GROUP BY threshold."
         }
       ]},
      {"v5.46.1", "2026-04-17T19:00:00Z",
       [
         %{
           title: "Chore: Elixir 1.17 → 1.18 upgrade",
           description:
             "Upgraded Elixir from 1.17 to 1.18 across Dockerfile, CI, and local tooling. Ran mix format --migrate to clean up deprecated unless syntax. OTP 27.2 unchanged."
         },
         %{
           title: "Chore: Dependency updates",
           description:
             "phoenix_live_view 1.1.27 → 1.1.28, geolix 2.0.0 → 2.1.0, geolix_adapter_mmdb2 0.6.0 → 0.7.0, swoosh 1.24.0 → 1.25.0, lazy_html 0.1.10 → 0.1.11."
         }
       ]},
      {"v5.46.0", "2026-04-17T18:00:00Z",
       [
         %{
           title: "Feat: Visitor profile deferred loading",
           description:
             "Visitor profile page now loads critical data (visitor record, profile stats) synchronously and defers heavy queries (timeline, sessions, IPs, fingerprints, ecommerce, scraper score) via progressive async loading. Page renders instantly with loading spinners that fill in as data arrives."
         },
         %{
           title: "Feat: Webhook status banner and history on visitor profile",
           description:
             "Visitor profile shows a prominent banner when the visitor has been flagged (red) or deactivated (green) via scraper webhook. New Webhook Activity section shows the full delivery log for the visitor: timestamp, event type, score, signals, and HTTP status."
         },
         %{
           title: "Feat: IPv6 CIDR prefix ranges in scraper webhook payload",
           description:
             "When the datacenter_asn signal fires, webhook payload now includes ip_ranges with /64 CIDR prefixes for all IPv6 addresses. Solves the IPv6 rotation problem where datacenter scrapers cycle addresses faster than individual flags can propagate. IPv4 addresses are unaffected. Deactivate payloads also include ip_ranges for cleanup."
         }
       ]},
      {"v5.45.2", "2026-04-16T23:00:00Z",
       [
         %{
           title: "Fix: Scraper detector now counts unique pages, not raw pageviews",
           description:
             "session_pageviews now uses uniqIf(url_path) instead of countIf — refreshes and duration pings no longer inflate the score. Thresholds lowered to match: 30 unique pages = high_pageviews, 100 = very_high_pageviews. HAVING threshold also lowered to 20 unique pages. Affects both dashboard queries and visitor profile score."
         }
       ]},
      {"v5.45.1", "2026-04-16T22:30:00Z",
       [
         %{
           title: "Feat: Scraper score and signals on visitor profile page",
           description:
             "Visitor profile now shows a real-time scraper score computed from the visitor's ClickHouse data (pageviews, IPs, timing, ASN, UA). Score badge is color-coded (red >= 85, amber >= 60) with verdict label. Individual signal badges shown below. Only displayed when score > 0."
         }
       ]},
      {"v5.45.0", "2026-04-16T22:00:00Z",
       [
         %{
           title: "Feat: Webhook delivery log on Scrapers page",
           description:
             "New webhook_deliveries PostgreSQL table logs every scraper webhook (flag + deactivate) with visitor ID, score, signals, HTTP status, and success/error. Scrapers page has a 'Webhook Log' tab showing last 50 deliveries with visitor links, signal badges, and status indicators. 30-day retention via existing ApiLogCleanup worker."
         }
       ]},
      {"v5.44.3", "2026-04-16T21:00:00Z",
       [
         %{
           title: "Security: three hardening fixes from audit",
           description:
             "1) Webhook URL validation — rejects localhost, link-local, missing scheme/host. 2) Visitor lookup in webhook handlers scoped by site_id — prevents cross-tenant data access via forged visitor UUIDs. 3) Webhook response body no longer rendered in UI — only HTTP status code shown, eliminating SSRF read-back channel."
         }
       ]},
      {"v5.44.2", "2026-04-16T20:00:00Z",
       [
         %{
           title: "Fix: Stripe sync crash on unexpanded product object",
           description:
             "product field on invoice line items is a string ID (not expanded map). get_in crashed with Access.get/3 on the string. Now checks if product is a map before accessing nested name, falls back to line description."
         }
       ]},
      {"v5.44.1", "2026-04-16T19:30:00Z",
       [
         %{
           title: "Feat: Braintree product data enrichment",
           description:
             "Braintree sync now extracts plan-id from transaction XML and populates the items column with product name, price, quantity, and category (subscription/one_time). New syncs going forward will appear in the Top Products table."
         }
       ]},
      {"v5.44.0", "2026-04-16T19:00:00Z",
       [
         %{
           title: "Feat: LTV dashboard cards, top customers table, Stripe product data",
           description:
             "Ecommerce page now shows all-time LTV stats (avg net/gross LTV, orders per customer, refund rate) in indigo cards, plus period customer count. Top Customers by LTV table with clickable visitor links, gross/net revenue, order count, and date range. Stripe sync now extracts product line items from expanded invoices — new syncs populate the items column for Top Products."
         }
       ]},
      {"v5.43.2", "2026-04-16T18:00:00Z",
       [
         %{
           title: "UX: Sortable columns on Site Search top terms table",
           description:
             "Click Search Term, Searches, or Searchers column headers to sort. Click again to toggle ascending/descending. Sort indicator arrow shown on active column."
         }
       ]},
      {"v5.43.1", "2026-04-16T17:30:00Z",
       [
         %{
           title: "Perf: Progressive rendering on Site Search page",
           description:
             "Search terms table and filter pills load first (critical path), then stats cards, trend chart, and search pages stream in progressively. Page no longer blocked by the slowest query."
         }
       ]},
      {"v5.43.0", "2026-04-16T17:00:00Z",
       [
         %{
           title: "Feat: Site Search param filter + param badges on search terms",
           description:
             "Ingest now records which URL parameter matched each search query (_search_param in event properties). Site Search page shows filter pills by parameter (e.g. ?q=, ?search=, ?keyword=) with counts. Each search term row shows a param badge. Filter to see only terms from a specific parameter. Data flows from new events forward — existing events won't have the param tag."
         }
       ]},
      {"v5.42.0", "2026-04-16T16:00:00Z",
       [
         %{
           title: "Feat: Site Search page redesign",
           description:
             "Completely rebuilt Site Search page. Stats cards (total searches, unique searchers, unique terms, searches per searcher). Search volume bar chart trend. Top Search Terms table with avg-per-person column. Search Pages sidebar showing which pages trigger searches. Config banner showing tracked URL parameters with link to Settings. 90-day date range option. All 4 queries run in parallel."
         }
       ]},
      {"v5.41.0", "2026-04-16T15:00:00Z",
       [
         %{
           title: "Feat: Configurable site search query parameters",
           description:
             "Sites can now configure which URL query parameters identify internal search queries (Settings > Content > Site Search). Defaults to q, query, search, s, keyword when unconfigured. Custom params take precedence over defaults."
         }
       ]},
      {"v5.40.5", "2026-04-16T14:30:00Z",
       [
         %{
           title: "UX: Show full webhook request payload and response in Scrapers modal",
           description:
             "Send webhook and Deactivate buttons now show the full JSON request body, target URL, response status, and response body in a scrollable detail panel below the buttons."
         }
       ]},
      {"v5.40.4", "2026-04-16T14:00:00Z",
       [
         %{
           title: "Fix: Webhook URL is now the full endpoint path, not base URL",
           description:
             "Webhook URL field accepts the complete endpoint (e.g. https://app.com/api/webhooks/spectabas/scraper). No longer prepends /api/webhooks/spectabas/scraper. Deactivate appends /deactivate to the configured URL."
         }
       ]},
      {"v5.40.3", "2026-04-16T13:30:00Z",
       [
         %{
           title: "UX: Show webhook response detail on send/deactivate",
           description:
             "Send webhook and Mark as not scraper buttons now display the full response or error message instead of just 'Sent!' or 'Failed'."
         }
       ]},
      {"v5.40.2", "2026-04-16T13:00:00Z",
       [
         %{
           title: "Fix: Webhook config fields clearing each other on keystroke",
           description:
             "Webhook URL/secret inputs read from @site (saved DB record) instead of @form (changeset). Every phx-change re-rendered the unsaved nil values, clearing user input. Now reads from @form so values track the changeset."
         }
       ]},
      {"v5.40.0", "2026-04-16T12:00:00Z",
       [
         %{
           title: "Feat: Scraper detection webhooks",
           description:
             "Per-site webhook configuration (URL + Bearer secret) in Settings > Advanced. When a visitor crosses the scraper detection threshold, a POST is sent with visitor identifiers (IPs, external ID, user ID), score, signals, and activation delay (0h for score >= 95, 48h otherwise). Oban worker scans every 15 min. Re-sends on score escalation (suspicious → certain). Manual Send/Deactivate buttons on Scrapers page detail modal. Deactivation clears the flag and notifies the receiving app."
         }
       ]},
      {"v5.39.1", "2026-04-15T05:30:00Z",
       [
         %{
           title: "Feat: External ID visible on visitor profile page",
           description:
             "Visitor profile now shows the External ID field (from the identity cookie) below User ID when set."
         }
       ]},
      {"v5.39.0", "2026-04-15T05:00:00Z",
       [
         %{
           title: "Feat: External identity cookie support for cross-cookie visitor merging",
           description:
             "Sites can now configure an external identity cookie name (e.g. _puppies_fp) in Settings. When set, the tracker reads that cookie from the customer's domain and sends its value as _xid with every event. Ingest resolves visitors by external_id first — if a visitor clears their _sab cookie but the external cookie persists, they are merged back to the same visitor profile. Includes: migration for identity_cookie_name on sites + external_id on visitors with partial index, tracker data-xid-cookie attribute, snippet auto-generation, Visitors.find_by_external_id/2 and set_external_id/2, and 10 new unit tests."
         }
       ]},
      {"v5.38.3", "2026-04-15T04:00:00Z",
       [
         %{
           title: "Diag: /health/test-attribution endpoint for live verification",
           description:
             "Admin endpoint that inserts synthetic events + orders into ClickHouse, runs all three attribution models (any/first/last), verifies non-zero revenue, and cleans up. Returns a JSON pass/fail report with per-model row counts, revenue totals, and source lists."
         }
       ]},
      {"v5.38.2", "2026-04-15T03:00:00Z",
       [
         %{
           title: "Test: Revenue attribution integration tests for all three touch models",
           description:
             "New integration test inserts synthetic events (2 visitors, 2 sources each, 2 orders) into ClickHouse and asserts: any/first/last touch all return non-zero revenue; first touch credits earliest source (google.com); last touch credits latest source (facebook.com); first and last have equal total revenue; any >= first (multi-attribution). Run with: mix test --only integration."
         }
       ]},
      {"v5.38.1", "2026-04-15T02:00:00Z",
       [
         %{
           title: "Fix: First/last touch attribution actually shows revenue now",
           description:
             "v5.38.0 switched first/last to daily_session_facts which had no data yet. Reverted to the events table (same source as 'any touch' which works). All three models now use identical query structure — same events table, same filters, same LEFT JOIN to ecommerce. Only difference: any = GROUP BY (visitor, source, platform), first = argMin(source, timestamp) per visitor, last = argMax. Removed session_facts dependency."
         }
       ]},
      {"v5.38.0", "2026-04-15T01:00:00Z",
       [
         %{
           title: "Fix: Revenue Attribution first/last touch now working",
           description:
             "Rebuilt first and last touch attribution as single SQL queries (same proven pattern as 'any touch' which always worked). First/last touch use daily_session_facts to find the first/last source per visitor in the date range — fast and reliable. Dropped the broken two-query merge approach and the 'First Click' (first_ever) model that scanned all history. Three models now: Last Touch (default), First Touch, Any Touch."
         }
       ]},
      {"v5.37.2", "2026-04-15T00:00:00Z",
       [
         %{
           title: "Feat: Acquisition drilldowns now show engagement metrics (safe approach)",
           description:
             "Sources and UTM tabs show Bounce Rate, Avg Duration, and Pages/Session alongside the existing columns. Unlike the v5.37.0 attempt that rewrote core queries (causing blank results), this version keeps the original fast queries untouched and enriches the results with a separate lightweight query against the pre-materialized daily_session_facts table. Engagement columns hidden on mobile for space."
         }
       ]},
      {"v5.37.1", "2026-04-14T23:00:00Z",
       [
         %{
           title: "Fix: Revert acquisition query rewrites that caused blank results",
           description:
             "The session-level subquery rewrites for top_sources, top_utm_dimension, and channel_detail were causing blank results on the Acquisition drilldown and Revenue Attribution campaign tab. Reverted to the original flat GROUP BY queries. Engagement metrics (bounce rate, duration, pages/session) on drilldowns will be added via a separate lightweight query in a follow-up rather than rewriting the core queries."
         }
       ]},
      {"v5.37.0", "2026-04-14T22:00:00Z",
       [
         %{
           title: "Feat: 6 new ad platform click ID tracking",
           description:
             "Added click ID capture for Pinterest (epik), Reddit (rdt_cid), TikTok (ttclid), Twitter/X (twclid), LinkedIn (li_fat_id), and Snapchat (ScCid). Click IDs are extracted from landing URLs, persisted in sessionStorage, and stored in ClickHouse for platform-level ROAS attribution. Colored platform pills added across Revenue Attribution, Integration Log, Settings, and all Ad Effectiveness pages."
         },
         %{
           title: "Feat: Acquisition drilldown now shows engagement metrics",
           description:
             "The Sources and UTM tabs on the Acquisition page now show Visitors, Bounce Rate, Avg Duration, and Pages/Session alongside pageviews and sessions — matching the Channels overview. Previously these columns were only visible at the channel level, not when drilling into individual sources."
         }
       ]},
      {"v5.36.5", "2026-04-14T21:00:00Z",
       [
         %{
           title: "Feat: Slack deploy notifications now include changelog",
           description:
             "The Slack deploy message now includes the changelog entries for the deployed version. Version moved to a @version module attribute."
         }
       ]},
      {"v5.36.4", "2026-04-14T20:00:00Z",
       [
         %{
           title: "Perf: Insights page loads instantly with async anomaly detection",
           description:
             "The Insights page was blocking in mount while AnomalyDetector ran multiple ClickHouse comparison queries (7d vs prior 7d across traffic, SEO, revenue, ads). Now loads async — the cached AI analysis shows immediately, anomalies load in background with a spinner. Same pattern as all other dashboard pages."
         }
       ]},
      {"v5.36.3", "2026-04-14T19:00:00Z",
       [
         %{
           title: "Fix: GSC sync now deletes before inserting (prevents stale data accumulation)",
           description:
             "The GSC and Bing Webmaster sync was inserting new rows without clearing existing data for the same date. Google revises search data retroactively — queries that drop below thresholds disappear from later API responses but their old rows stayed in our table. Over time (especially with backfill + daily sync overlap), this accumulated stale rows that inflated click/impression totals. Both Google and Bing sync functions now DELETE existing rows for the (site, date, source) before inserting the fresh batch. To fix the April 10-11 hump: re-run the GSC backfill from Site Settings (it will delete-then-insert clean data for each date)."
         }
       ]},
      {"v5.36.2", "2026-04-14T18:00:00Z",
       [
         %{
           title: "Fix: GSC duplicate data deduplication endpoint",
           description:
             "Added /health/dedupe-search-console admin endpoint. Detects duplicate rows in search_console (from overlapping daily sync + backfill runs) and triggers OPTIMIZE TABLE FINAL to force ReplacingMergeTree deduplication. The daily_trends and sparkline queries dropped FINAL earlier (to fix alias bugs), so unmerged duplicates were inflating the April 10-11 data hump."
         }
       ]},
      {"v5.36.1", "2026-04-14T17:00:00Z",
       [
         %{
           title: "Fix: Dashboard chart blanking out after cards load",
           description:
             "The timeseries chart appeared briefly then went blank when deferred results (top pages, sources, etc.) arrived. Each deferred result caused a LV re-render; without phx-update='ignore', morphdom replaced the canvas element and destroyed Chart.js's reference. Added phx-update='ignore' back to the timeseries chart and map divs — safe because these have stable ids. Also fixed bounce rate showing >100% (was sum(is_bounce) on raw events instead of session-grouped countIf(pv=1))."
         }
       ]},
      {"v5.36.0", "2026-04-14T16:00:00Z",
       [
         %{
           title: "Perf: Async mount on all 26 dashboard pages",
           description:
             "Every dashboard page now loads data asynchronously — the page renders instantly with a loading spinner, data fills in when ClickHouse responds. Previously 24 of 27 data pages blocked in mount for 3-10 seconds. Users see the page header, range selector, and sidebar immediately."
         },
         %{
           title: "Perf: 6 ClickHouse query optimizations",
           description:
             "UTM bloom filter indexes (2-3x faster campaign queries). daily_campaign_rollup (50-100x faster Campaigns page). overview_stats_fast for all ranges (5-10x faster Today/Yesterday). daily_session_facts (10-20x faster entry/exit pages). visitor_attribution table (10-50x faster revenue attribution). Seek-based visitor_log pagination (10-20x faster on deep pages)."
         },
         %{
           title: "Fix: Bounce rate was showing >100%",
           description:
             "overview_stats_fast was calculating bounce rate as sum(is_bounce) across all raw event rows. Since is_bounce defaults to 1 on every event, a session with 10 events contributed 10 to the numerator but only 1 to the denominator — producing bounce rates like 1121%. Restored the correct session-grouped subquery: countIf(pv=1)/count() where pv is pageviews per session."
         },
         %{
           title: "Fix: Dashboard timeseries chart reliable rendering",
           description:
             "The main dashboard chart sometimes rendered partially or flickered. Two fixes: (1) Chart now reads initial data from a data-chart JSON attribute (race-free, same pattern as Search Keywords). (2) Removed the redundant timeseries re-push when deferred results complete — was causing Chart.js to re-animate identical data."
         },
         %{
           title: "Fix: 10 mobile UX improvements",
           description:
             "Visitor Log hides 3 columns on mobile. Search Keywords and Scrapers headers stack on narrow screens. Settings tabs scroll horizontally. Modal close buttons enlarged for touch targets. Bot Traffic modal hides Network column. Journeys bounce table scrollable, pills truncate at 120px."
         }
       ]},
      {"v5.33.0", "2026-04-14T12:00:00Z",
       [
         %{
           title: "Feat: 9 dashboard improvements from feature audit",
           description:
             "Settings broken into 4 tabs (General, Content, Integrations, Advanced). Journeys page has inline config panel for content prefixes + conversion pages. Goals show top 3 traffic sources per goal. Events are clickable to see property key/value breakdown. Bot Traffic has a daily trend chart (bot vs human). Sidebar shows anomaly badges (red/amber dots) on sections with detected anomalies. Realtime page has visitor filter (by email/IP/country). Pages table shows device split column (Desktop/Mobile/Tablet %). Revenue Attribution adds First Click model (visitor's first-ever referrer, not just first in converting session)."
         }
       ]},
      {"v5.32.0", "2026-04-14T09:00:00Z",
       [
         %{
           title: "Feat: Visitor Journeys redesign — page-type grouping + outcome segmentation",
           description:
             "Complete rewrite. URLs are now grouped by page type using your content prefixes (/listings/* becomes 'Listings', etc.) so thousands of unique paths collapse into recognizable patterns. Journeys are split into three sections: Converter journeys (paths that touched a conversion page), Engaged journeys (3+ pages, no conversion), and Bounce paths (single-page sessions by type and source). Consecutive identical page types are collapsed (Listings → Listings → Listings → Contact becomes Listings → Contact). Each journey shows visitor count, avg duration, and top 3 traffic sources. Conversion pages are site-configurable via Settings → Visitor Journeys (one URL prefix per line). Stats cards show total sessions, multi-page sessions, pages/session, converted, and bounced."
         }
       ]},
      {"v5.31.0", "2026-04-14T08:00:00Z",
       [
         %{
           title: "Fix: AI analysis persists across page visits",
           description:
             "InsightsCache no longer expires after 24 hours. Generated analyses persist indefinitely until the user clicks Regenerate. The 'cached for 24 hours' message is replaced with 'click Regenerate for fresh data'. Also removed debug logging from insights_live mount."
         },
         %{
           title: "Feat: AI analysis now uses 7 additional data sources",
           description:
             "The AI prompt previously sent only traffic summary, GSC overview, revenue, and ad spend. Now includes: engagement metrics (bounce rate, avg duration, pages/session), top 10 pages by pageviews, top 5 traffic sources, top 5 countries, device split (mobile/desktop/tablet %), top 10 search queries with clicks/impressions/position, new keywords discovered this week, and scraper activity summary. System prompt word limit raised from 500 to 800 to accommodate the richer analysis."
         }
       ]},
      {"v5.30.0", "2026-04-14T07:00:00Z",
       [
         %{
           title: "Security: Role-based write restrictions for viewers and analysts",
           description:
             "Viewers are now fully read-only across all dashboard pages — they can browse any permitted site but cannot create goals, funnels, campaigns, email report subscriptions, save segments, or modify any settings. Analysts can do all of those but cannot modify site settings (integrations, GDPR mode, timezone, tracking config, credentials, sync triggers, backfills). Implemented via LiveView attach_hook on :handle_event that halts write events before they reach the handler. Settings has 12 guarded events, plus 6 other pages (goals, funnels, campaigns, site segments, email reports, reports). Exports and AI generation remain accessible to all roles."
         },
         %{
           title: "Chore: Deduplicate shared helpers",
           description:
             "Moved blank_to_dash/1 and sort_arrow/3 into TypeHelpers (was copy-pasted across 4 files). Removed local format_number/1 from search_keywords_live (now uses TypeHelpers). Removed local to_int/1 from application.ex. Consolidated two startup backfill tasks into one."
         }
       ]},
      {"v5.29.1", "2026-04-14T05:30:00Z",
       [
         %{
           title: "Fix: Scraper detection perf + datacenter ASN matching",
           description:
             "Three fixes: (1) Query was running TWICE (once for summary, once for candidates) — merged into a single query with summary computed in Elixir from the same result. (2) Unbounded groupArray() for page_paths/timestamps caused OOM on high-volume visitors — capped to groupArray(50)/groupArray(100). HAVING threshold raised to 30+ pageviews (was 20). (3) ASN column was ip_asn_org which stores just 'OVH SAS' (no prefix) — the detector's @datacenter_asns matches 'AS16276'. Switched to ip_org which stores the full 'AS16276 OVH SAS' string. Also added is_datacenter fallback from the 900-entry ASNBlocklist so datacenter detection works even for ASNs not in the 10-entry hardcoded list."
         }
       ]},
      {"v5.29.0", "2026-04-14T05:00:00Z",
       [
         %{
           title: "Feat: Scraper Detection page under Audience",
           description:
             "New Scrapers page detects visitors that look like scrapers via weighted signals: datacenter ASN, IP rotation with same cookie (3+ IPs), spoofed mobile UA on datacenter IP, 50+/200+ session pageviews, systematic crawl (>80% of paths match configured content prefixes), no referrer, robotic request timing (std dev <300ms), emulator resolutions. Pure Spectabas.Analytics.ScraperDetector module with score/1 and verdict/1. Dashboard shows summary cards + sortable table of flagged visitors with signal pills. Click any row for full details (UA, page paths, signals explained, link to full visitor profile). Each site configures its own content path prefixes in Site Settings → Scraper Detection (the systematic-crawl signal is skipped when empty). 30 unit tests cover each signal plus composite profiles."
         },
         %{
           title: "Feat: Site Settings — Scraper Detection content prefixes",
           description:
             "New site field scraper_content_prefixes (array of strings). Textarea on Site Settings, one prefix per line. Drives which URL paths count as content for the systematic-crawl scraper detection signal."
         }
       ]},
      {"v5.28.1", "2026-04-14T04:00:00Z",
       [
         %{
           title: "Fix: Bot UA modal close (×) button",
           description:
             "The close button wasn't firing clicks — the modal used a `pointer-events-none` wrapper with a `pointer-events-auto` inner card to enable backdrop-click-to-close. Some browsers treat that trick inconsistently. Simplified: backdrop and modal card are now separate top-level fixed-positioned elements with no pointer-events gymnastics. × button now works reliably, and backdrop click still closes. Also made the close button bigger and gave the header sticky positioning so it stays visible when scrolling through long UA details."
         }
       ]},
      {"v5.28.0", "2026-04-14T03:30:00Z",
       [
         %{
           title: "Feat: Bot Traffic — click user agent to see full details",
           description:
             "Top Bot User Agents rows are now clickable. Modal shows the full user agent string (no truncation), parsed browser/OS/device type, network/ASN org, hit counts, unique visitor + IP counts, first/last seen timestamps, top 10 pages targeted, and top 10 IPs (each linking to the IP profile page). New Analytics.bot_ua_details/4 query."
         },
         %{
           title: "Feat: Visitor Log — sortable columns",
           description:
             "Pages, Duration, and Last Seen column headers are now clickable to sort. Click toggles direction; switching columns defaults to descending (so 'Pages' defaults to most-pages-first, the most useful view). Added a Last Seen column to the table. Pagination switched from cursor to offset-based so sorting works correctly across pages."
         }
       ]},
      {"v5.27.2", "2026-04-14T02:45:00Z",
       [
         %{
           title: "Fix: Backfill ASN flags even when a few stray rows exist",
           description:
             "The v5.27.1 startup check skipped backfill if any flagged rows existed — but 59 rows from some brief prior window (out of millions of events) isn't meaningfully backfilled. Lowered the threshold: now triggers backfill if flagged rows < blocklist_size × 10 (a healthy site should have many multiples more flagged rows than total blocklist entries). Also added /health/backfill-asn-flags admin endpoint so you can force-run the backfill manually without redeploying."
         }
       ]},
      {"v5.27.1", "2026-04-14T02:30:00Z",
       [
         %{
           title: "Fix: ASN blocklist parser + Network page datacenter/VPN/Tor counts",
           description:
             "The ASN blocklist loader was silently failing on every line because priv/asn_lists/*.txt lines look like 'AS45090 # Tencent cloud...' and the parser called Integer.parse on the whole line (which fails immediately on the A). So the ETS tables have been empty since inception — every event got ip_is_datacenter/vpn/tor = 0, and the Network page's three percentage cards always showed zero. Fixed the parser to strip # comments and the optional AS prefix before parsing. Added a one-shot BackfillASNFlags Oban worker that walks the events table once and applies the flags to existing historical rows. Application startup auto-triggers the backfill if the blocklist loaded but no events in the last 30 days are flagged. ASNBlocklist now logs row counts on load and exposes sizes/0 and all/1 for diagnostics."
         }
       ]},
      {"v5.27.0", "2026-04-14T02:00:00Z",
       [
         %{
           title: "Feat: Historical backfill for Search Console / Bing Webmaster",
           description:
             "The daily sync worker only pulls 2-4 days ago, so sites with newer GSC/Bing connections only have ~10 days of chart data visible. Added two backfill buttons on Site Settings → Integrations: 'Backfill 90d' and 'Backfill 16mo' (Google's max retention). Runs via Oban with a 200ms pause between days to respect rate limits. New /health/diag block `search_console_coverage` shows per-site, per-day row counts so you can see exactly which dates have data and where the gaps are."
         }
       ]},
      {"v5.26.9", "2026-04-14T01:30:00Z",
       [
         %{
           title: "Fix: Search Keywords range buttons (7d/30d/90d) now actually change data",
           description:
             "Clicking 7d, 30d, or 90d wasn't updating any chart. Two layered bugs: (1) phx-update='ignore' on the chart containers meant LiveView never applied the new DOM id on re-render, so the hook never saw the new data-chart attribute. (2) chart_key was derived from System.unique_integer so it changed on EVERY load_data call — including sort clicks, which would have unnecessarily destroyed+remounted charts. Dropped phx-update='ignore' so id changes now trigger clean element replacement and hook remount. chart_key is now range + source so it changes only when the displayed data should change. drawer_chart_key is now derived from the query so clicking a different query while the drawer is open also forces a proper remount. Morphdom's smart diffing leaves unchanged canvases alone between re-renders, so Chart.js state is preserved when it should be."
         }
       ]},
      {"v5.26.8", "2026-04-14T01:00:00Z",
       [
         %{
           title: "Fix: Search Keywords charts, round 3 — Date-column alias collision",
           description:
             "After the total_clicks/total_impressions fix, daily_trends was still returning 0 rows. Render logs surfaced NO_COMMON_TYPE (Code 386): toString(date) AS date aliased the Date column to a String, then GROUP BY date and ORDER BY date became ambiguous between the Date source column and the String alias. Renamed the alias to `bucket` and kept GROUP BY/ORDER BY on the Date source column. Applied to daily_trends, drawer_timeseries, and query_sparklines. Template + build_chart_jsons updated to read 'bucket' instead of 'date'. Added a catch-all CLAUDE.md note: aliases in ClickHouse must never collide with source column names, even if the type differs — both ILLEGAL_AGGREGATION and NO_COMMON_TYPE come from this class of bug."
         }
       ]},
      {"v5.26.7", "2026-04-14T00:30:00Z",
       [
         %{
           title: "Diag: SearchChart hook console logs + drawer_timeseries no-FINAL",
           description:
             "SearchChart hook now logs [SearchChart] id raw-length data-chart-preview and dataset counts to the browser console so we can see what the hook is actually receiving. Also dropped FINAL from drawer_timeseries (same silent-zero-rows issue as daily_trends) and added row-count + error logging."
         }
       ]},
      {"v5.26.6", "2026-04-14T00:00:00Z",
       [
         %{
           title: "Fix: Search Keywords ILLEGAL_AGGREGATION across daily_trends + drawer",
           description:
             "The SQL aliases sum(clicks) AS clicks and sum(impressions) AS impressions were shadowing the underlying column names. ClickHouse then interpreted the sum(impressions) inside the if(...) CTR calculation as sum(the_alias) = nested aggregation → ILLEGAL_AGGREGATION error. FINAL was silently returning 0 rows to hide the error; once dropped, the actual error surfaced. Renamed aliases to total_clicks / total_impressions (same pattern as the already-working query_stats). Fixed in daily_trends AND all four drawer queries (timeseries, pages, devices, countries). Drawer 'pages ranking' table should now populate too."
         }
       ]},
      {"v5.26.5", "2026-04-13T23:30:00Z",
       [
         %{
           title: "Fix: Search Keywords daily_trends + sparklines queries",
           description:
             "daily_trends and query_sparklines were dropping FINAL from the ReplacingMergeTree, which was returning 0 rows on large search_console tables (likely hitting ClickHouse's default max_execution_time mid-FINAL-merge and returning empty). Without FINAL we might briefly over-count while a sync is in flight, but the per-day sums are stable enough for a trend chart — and the big Stats card at the top still uses FINAL for exact aggregate numbers. Also added explicit {:error, _} logging so future failures are visible in logs instead of silently returning []."
         }
       ]},
      {"v5.26.4", "2026-04-13T23:00:00Z",
       [
         %{
           title: "Diag: Search Keywords query timing + row counts",
           description:
             "Each SearchKeywords load_data query now logs [SearchKeywords:slow] name took=Xms when it exceeds 1 second, and daily_trends always logs its returned row count. Also bumped the per-task timeout from 15s to 30s since FINAL on search_console with 6.8M+ rows + GROUP BY date can be heavy on larger sites."
         }
       ]},
      {"v5.26.3", "2026-04-13T22:30:00Z",
       [
         %{
           title: "Fix: Search Keywords sidebar highlight",
           description:
             "The Search Keywords page wasn't passing active=\"search-keywords\" to the dashboard layout, so the sidebar defaulted to highlighting Dashboard. Fixed. Also added a search_console block to /health/diag showing rows/date-range/sources per site so we can quickly verify whether a site has GSC/Bing data flowing."
         }
       ]},
      {"v5.26.2", "2026-04-13T22:00:00Z",
       [
         %{
           title: "Fix: Search Keywords charts actually render data now",
           description:
             "Rather than fight the push_event/hook-mount race with timing workarounds, the charts now read their initial data from a data-chart JSON attribute rendered directly into the HTML. Guaranteed delivery — the data is in the DOM by the time mounted() runs. Each reload gets a new chart_key suffix on the DOM id, so LiveView swaps the whole element and the hook remounts fresh with the new data. Applied to all three page charts, four drawer charts, and per-query sparklines. Removed all the old push_event chart machinery."
         }
       ]},
      {"v5.26.1", "2026-04-13T21:30:00Z",
       [
         %{
           title: "Fix: Search Keywords charts now populate with data",
           description:
             "The three trend charts and per-query sparklines were rendering empty Chart.js frames because the server push_event fired during mount — before the client's chart hooks had registered their handleEvent listeners. Fixed by deferring the initial push via send(self(), :push_initial_charts), which routes through the message queue and runs after LiveView finishes rendering. Same fix applied to the query drawer: load_drawer_data is now triggered by send(self(), {:load_drawer, query}) after the drawer DOM renders. Also added phx-update='ignore' to all chart container divs so LiveView diffs don't mangle the Chart.js-managed canvas."
         }
       ]},
      {"v5.26.0", "2026-04-13T21:00:00Z",
       [
         %{
           title: "Feat: Campaigns page auto-detects from events",
           description:
             "The Campaigns page was only showing pre-created campaigns from the UTM builder — silently missing any utm_campaign traffic that wasn't pre-created. Now the page is driven by actual ClickHouse events: every unique (utm_campaign, utm_source, utm_medium) triple in the selected date range is a row, whether it was pre-built or not. Saved campaigns get their nice name displayed in place of the raw utm value. Detected-but-unsaved campaigns get a one-click 'Save to Builder' button. Saved campaigns with no traffic still show (grayed) so you see everything you set up. Date range selector (7d/30d/90d) replaces the hardcoded 30d. campaign_performance query now groups by campaign+source+medium."
         }
       ]},
      {"v5.25.0", "2026-04-13T20:30:00Z",
       [
         %{
           title: "Feat: Search Keywords overhaul — trends, sparklines, drill-in, SEO insights",
           description:
             "Search Keywords page now shows per-day Clicks+Impressions combo chart, CTR trend, and Avg Position trend (inverted y-axis) at the top. Each row in Top Queries has a 30-day clicks sparkline. Clicking any row opens a right-side drawer with four per-query time series (clicks, impressions, CTR, position), the pages ranking for that query, and device+country splits. Added two new SEO-actionable sections: Opportunity Queue (queries at pos 8-20 ranked by projected extra clicks if moved to top 3) and Keyword Cannibalization (queries where 3+ of your pages compete in the top 30 — expandable to see which pages are fighting). All queries parallelized via Task.async."
         },
         %{
           title: "Feat: Generic SearchChart Chart.js hook",
           description:
             "New multi-instance chart hook supporting line, bar, and combo charts with optional dual y-axes and inverted y-axis. Each chart filters events by DOM id, so many charts can coexist on one page. Used for all charts on the Search Keywords page."
         }
       ]},
      {"v5.24.0", "2026-04-13T19:30:00Z",
       [
         %{
           title: "Perf: Four new rollup tables for sub-second dashboard cards",
           description:
             "Added daily_page_rollup, daily_source_rollup, daily_geo_rollup, and daily_device_rollup — AggregatingMergeTree tables populated by the existing DailyRollup cron. top_pages, top_sources, top_regions, top_browsers, top_os, visitor_locations, and timezone_distribution on the dashboard overview now read from these for prior days and raw events only for today+yesterday. Was 3-7 seconds per card, should be a few hundred ms. Detail pages keep using the raw-events variants so they still have avg_duration, city drill-down, etc. Segmented dashboard queries also stay on raw events since rollups are unsegmented. Backfill runs automatically on first deploy — takes a few minutes on large sites."
         },
         %{
           title: "Fix: Chart rendering during progressive load",
           description:
             "v5.23.0's progressive rendering was pushing empty map-data/bar-data during the critical path, briefly clearing those charts for 3-7 seconds until the deferred data arrived. Now critical path only pushes the timeseries chart data; map and timezone bar are pushed individually as their queries finish. Added a defensive final re-push when all deferred results complete, to handle any hook that missed an earlier push."
         }
       ]},
      {"v5.23.0", "2026-04-13T18:30:00Z",
       [
         %{
           title: "Perf: Progressive dashboard — cards appear as queries finish",
           description:
             "Previously the dashboard waited for the slowest deferred query (often 8-9s for identified_users, 7s for entry_pages) before rendering ANY of the cards below the chart. Refactored to fire-and-forget tasks that send each result back as it completes — Top Pages, Top Sources, map, etc. pop in independently between 0.5s and 7s. The LiveView remains interactive while cards load. Stale results are dropped when you change ranges mid-load."
         },
         %{
           title: "Perf: identified_users card 1000x faster",
           description:
             "The identified users count was doing SELECT DISTINCT visitor_id over millions of raw events in ClickHouse, then shipping the entire list through a Postgres IN ($1,$2,…,$N) clause. Replaced with a pure Postgres range scan on a new partial index (visitors_identified_by_site_last_seen_idx) — 8-9 seconds becomes microseconds."
         },
         %{
           title: "Diag: Dashboard:slow log tag",
           description:
             "Added timing instrumentation to every critical and deferred dashboard query. Queries over 500ms log at notice level with the prefix [Dashboard:slow] and include the query name, site id, date range, and duration. Makes it easy to identify slow dashboard queries from Render/AppSignal logs."
         }
       ]},
      {"v5.22.2", "2026-04-13T18:00:00Z",
       [
         %{
           title: "Diag: dashboard query timing logs",
           description:
             "Each critical-path and deferred dashboard query now logs its wall-clock duration when it exceeds 500ms (format: '[Dashboard:slow] stats site=X days=30 took=4210ms'). Filter AppSignal by that tag to see which query is the bottleneck on 7d/30d views. Also reverted v5.22.1's UNION ALL rollup path in overview_stats_fast back to the simpler single-query raw-events form while we narrow down the real bottleneck."
         }
       ]},
      {"v5.22.1", "2026-04-13T17:00:00Z",
       [
         %{
           title: "Perf: 7d chart and stats cards now use the rollup",
           description:
             "Lowered the daily_rollup threshold from 30 days to 7 days so the 7-day chart also benefits from pre-aggregated data. overview_stats_fast (the stats cards that block initial dashboard render) was still doing uniq(visitor_id) over the full range of raw events — rewrote it to split pv/visitors/sessions across rollup states (prior days) + raw event states (today+yesterday) via UNION ALL + uniqExactIfMerge for exact cross-day dedup. Bounce/duration stay as cheap per-event aggregates over the full range. Should cut 7d and 30d load times substantially."
         }
       ]},
      {"v5.22.0", "2026-04-13T15:15:00Z",
       [
         %{
           title: "Fix: Consistent visitor counts across date ranges (1d/7d/30d)",
           description:
             "The 7-day chart was overcounting visitors because Analytics.timeseries used uniq(visitor_id) over ALL events — including RUM, duration, identify, and custom events — not just pageviews. A visitor firing only a RUM beacon would count as a visitor for that day. Now filters to event_type='pageview' with uniqExactIf, matching overview_stats. Also switched timeseries_fast from uniq (HyperLogLog approximation) to uniqExact for exact counts that match the 1-day view."
         },
         %{
           title: "Perf: Daily rollup table for fast 30/90-day chart loads",
           description:
             "New daily_rollup ClickHouse table (AggregatingMergeTree with uniqExactIfState) pre-aggregates per-site daily pageviews, visitors, and sessions. Populated by a daily Oban cron at 01:30 UTC. timeseries_fast now queries the rollup for complete prior days and raw events only for today + yesterday (covers the cron-delay gap). Dramatically faster on long ranges for high-volume sites. One-time historical backfill runs automatically on startup if the rollup is empty."
         }
       ]},
      {"v5.21.0", "2026-04-10T15:00:00Z",
       [
         %{
           title: "Perf: Smarter payment sync — today only with automatic catchup",
           description:
             "Stripe and Braintree cron syncs now fetch today's data only, cutting API calls and duration in half. If the last successful sync was more than 6 hours ago (e.g., after an outage), yesterday is automatically included to prevent data gaps."
         },
         %{
           title: "Feat: Slack notifications for sync failures",
           description:
             "New Spectabas.Notifications.Slack module sends alerts to a Slack channel when payment syncs fail. Set SLACK_WEBHOOK_URL env var to enable. Includes site name, error details, and suggested action."
         }
       ]},
      {"v5.20.0", "2026-04-09T20:00:00Z",
       [
         %{
           title: "Fix: First/last touch Revenue Attribution returning empty results",
           description:
             "First and last touch attribution queries were silently failing due to full events table scans hitting ClickHouse limits. Added signal filter to WHERE clause (matching any-touch approach) and error logging. Also fixed AOV calculation — ClickHouse non-Nullable Decimal returns 0 (not NULL) on LEFT JOIN misses, so avg() was diluted by thousands of zero rows. Now uses sum/count for correct AOV."
         }
       ]},
      {"v5.19.0", "2026-04-09T16:00:00Z",
       [
         %{
           title: "Feat: Campaign ID to name resolution in Revenue Attribution",
           description:
             "Revenue Attribution now matches utm_campaign values containing campaign IDs (not just names) to ad spend data. When PPC teams use campaign IDs in UTM parameters, the dashboard resolves them to human-readable campaign names from the ad platform."
         },
         %{
           title: "UX: Integration setup documentation links",
           description:
             "Each integration's Configure section now includes a direct link to its setup documentation, opening in a new browser tab."
         }
       ]},
      {"v5.18.0", "2026-04-09T12:00:00Z",
       [
         %{
           title: "Fix: Retry logic for transient transport errors across all integrations",
           description:
             "Created shared Spectabas.AdIntegrations.HTTP module wrapping Req.get/post with automatic 3-attempt retry on TransportError (:closed, :timeout, :econnrefused, etc.) with exponential backoff. Applied to all 7 integration platforms (Stripe, Google Ads, Bing Ads, Meta Ads, Google Search Console, Bing Webmaster, Braintree). Consolidated Braintree's per-function retry logic into the shared module. Fixes intermittent 'Braintree API error: %Req.TransportError{reason: :closed}' errors."
         }
       ]},
      {"v5.17.0", "2026-04-08T20:00:00Z",
       [
         %{
           title: "Feat: AppSignal APM integration",
           description:
             "Added AppSignal for error tracking, performance monitoring, and Oban job instrumentation. Phoenix requests, LiveView events, Ecto queries, and background jobs are auto-instrumented via Telemetry. Set APPSIGNAL_PUSH_API_KEY env var to activate."
         }
       ]},
      {"v5.16.0", "2026-04-08T19:30:00Z",
       [
         %{
           title: "Fix: Identify API returns 200 for unmatched visitors",
           description:
             "The /api/v1/sites/:id/identify endpoint now returns 200 with {ok: true, matched: false} when a visitor_id has no match, instead of 404. Prevents false error alerts on the calling server while still indicating the identify didn't link."
         }
       ]},
      {"v5.15.0", "2026-04-08T19:00:00Z",
       [
         %{
           title: "Perf: ClickHouse memory limits",
           description:
             "Added max_server_memory_usage_to_ram_ratio (75%) and per-query max_memory_usage (2GB) to prevent runaway memory growth without affecting query performance."
         },
         %{
           title: "Fix: Events Today comma formatting",
           description:
             "Admin dashboard Events Today count now displays with comma separators (e.g. 1,234,567)."
         }
       ]},
      {"v5.14.0", "2026-04-08T18:00:00Z",
       [
         %{
           title: "Perf: Minified tracker script",
           description:
             "Client-side tracking script (s.js) minified from 25.5KB to 12.1KB (52% reduction). All comments, whitespace, and verbose variable names removed. Zero functional changes — verified by 82 structural tests."
         },
         %{
           title: "Test: Comprehensive tracker script test suite",
           description:
             "Added 82 ExUnit tests covering every tracker function: fingerprinting, cookie/visitor ID management, pageview rate limiting, SPA support, duration tracking, send transport, public API, form abuse detection, outbound/download tracking, RUM/CWV, cross-domain support, and security properties."
         }
       ]},
      {"v5.13.0", "2026-04-07T14:00:00Z",
       [
         %{
           title: "Fix: Email case normalization",
           description:
             "All email addresses are now lowercased at every entry point — identify API, ecommerce API, Stripe sync, Braintree sync, and subscription imports. Existing emails in Postgres lowercased via migration. Ensures consistent matching across all payment providers."
         },
         %{
           title: "Perf: Dashboard range caching + fast overview stats",
           description:
             "Switching between 7d/30d/90d is now instant after first visit (cached in session). Overview stats use a lighter ClickHouse query for 7d+ ranges. Data cards show loading spinners while deferred queries run."
         },
         %{
           title: "Fix: Visitor cache periodic sweep",
           description:
             "ETS visitor cache now sweeps expired entries every 30 minutes instead of growing unbounded. Prevents overnight memory accumulation on high-traffic sites."
         },
         %{
           title: "Fix: Oban worker pileup prevention",
           description:
             "StripeSync, BraintreeSync, and AdSpendSync workers now have unique constraints preventing duplicate jobs. Previously 42 StripeSync workers were found executing simultaneously due to pileup."
         },
         %{
           title: "Perf: Async ecommerce transaction API",
           description:
             "Transaction API response time reduced from 200-800ms to single-digit ms. ClickHouse insert and visitor identification now run in background after responding."
         },
         %{
           title: "Fix: Braintree backfill moved to Oban",
           description:
             "Payment backfill now runs as an Oban job on the ad_sync queue instead of a Task.start, isolating it from the web DB pool and surviving deploys."
         },
         %{
           title: "Admin: Oban job management",
           description:
             "New /oban-admin endpoint for viewing executing jobs by worker and cancelling stuck jobs. Ingest diagnostics page shows per-worker breakdown of executing Oban jobs."
         },
         %{
           title: "Admin: API logs + ingest diagnostics access",
           description:
             "API logs and ingest diagnostics pages moved to /admin scope — superadmins can now access them. API logs page loads faster with async stats and estimated counts."
         }
       ]},
      {"v5.12.0", "2026-04-06T21:00:00Z",
       [
         %{
           title: "Fix: Braintree sync pagination",
           description:
             "Braintree search API returns max 50 results per request. Previously only the first page was fetched, missing most transactions on high-volume sites. Now uses Braintree's two-step search: (1) fetch all matching IDs via advanced_search_ids, (2) batch-fetch full transaction data in chunks of 50."
         },
         %{
           title: "Fix: Braintree backfill sync logging",
           description:
             "Backfill operations now write to the integration sync log (backfill_start, backfill ok/error with duration and day count). Previously backfills produced no log entries."
         },
         %{
           title: "Fix: Braintree credential validation",
           description:
             "Braintree API calls now validate credentials before making requests. Missing credentials return a clear error instead of silently making malformed API calls. Backfill aborts immediately on credential errors."
         },
         %{
           title: "Fix: Braintree refund error handling",
           description:
             "Refund fetch errors (401, 500, network failures) are now logged instead of being silently swallowed as empty results."
         },
         %{
           title: "Ingest diagnostics access",
           description:
             "Ingest diagnostics page moved from /platform/ingest to /admin/ingest — now accessible to superadmins, not just platform admins."
         }
       ]},
      {"v5.11.0", "2026-04-06T18:00:00Z",
       [
         %{
           title: "Infrastructure: ObanRepo separate connection pool",
           description:
             "Oban background jobs now use a dedicated 25-connection Postgres pool (ObanRepo), " <>
               "isolated from the web request pool (10 connections). Prevents sync workers from starving web requests."
         },
         %{
           title: "Infrastructure: Crash recovery for IngestBuffer",
           description:
             "Buffer persisted to disk every 10 seconds. On restart, recovered events are flushed " <>
               "to ClickHouse. Protects against data loss from OOM kills or hard crashes."
         },
         %{
           title: "Infrastructure: Enhanced health monitoring",
           description:
             "Health endpoint now reports buffer size, Oban queue depth, and returns 'overloaded' " <>
               "status when buffer >= 8,000 or pending jobs >= 500,000."
         },
         %{
           title: "Fix: Geography page showing single state",
           description:
             "Import-aware merge key was grouping all regions by country, collapsing 50 states " <>
               "into one California row. Fixed to merge by {country, region}."
         }
       ]},
      {"v5.10.0", "2026-04-06T12:00:00Z",
       [
         %{
           title: "Test coverage: 67 new tests (609 → 676)",
           description:
             "Added tests for: account lockout (threshold, below threshold), password complexity " <>
               "(numbers, letters, valid), Require2FA plug (redirect, expiry, pass-through), " <>
               "2FA verification endpoint, AI config (encrypt/decrypt, configured?, credentials), " <>
               "AI insights cache (put/get, TTL), sync log (create, query, cleanup), " <>
               "Bing date parser (timezone offsets), anomaly detector structure."
         },
         %{
           title: "Fix: account lockout double-counting",
           description:
             "Hammer.check_rate was called twice per login attempt (check + re-check on failure), " <>
               "causing lockout after 3 attempts instead of 5. Fixed to single check_rate call."
         },
         %{
           title: "Fix: exit rate insight accuracy",
           description:
             "Was using bounce rate (is_bounce) instead of actual exit rate. Now calculates " <>
               "true exit rate using last page per session via argMax. Skips homepages and terminal pages."
         },
         %{
           title: "Fix: Bing Webmaster data import",
           description:
             "Switched from GetQueryPageStats (0 rows) to GetQueryStats (5,872 rows). " <>
               "Fixed date parser for /Date(ms-offset)/ format. Added bulk sync (single API call)."
         }
       ]},
      {"v5.9.0", "2026-04-05T12:00:00Z",
       [
         %{
           title: "UX: Unified toast notifications",
           description:
             "Flash messages consolidated into a single modal toast in the top-right corner. " <>
               "Green checkmark for success (auto-dismiss), red X for errors (manual dismiss). " <>
               "Removed duplicate inline flash rendering from settings page."
         },
         %{
           title: "UX: Standardized button styling",
           description:
             "All buttons across the settings page now use consistent rounded-lg styling. " <>
               "Primary, secondary, and platform badge buttons all standardized."
         },
         %{
           title: "UX: Integration panel auto-refresh",
           description:
             "After Sync Now or Backfill, integration panels automatically refresh to show " <>
               "updated sync times and status without requiring a page reload."
         }
       ]},
      {"v5.8.0", "2026-04-05T12:00:00Z",
       [
         %{
           title: "Feature: AI-powered insights",
           description:
             "Configure an AI provider (Anthropic Claude, OpenAI, Google Gemini) per site in Settings. " <>
               "Generate AI Analysis button on Insights page sends aggregated metrics to AI for prioritized " <>
               "weekly action items. Results cached 24 hours. Weekly AI email sent Monday mornings."
         },
         %{
           title: "Feature: Enhanced email reports",
           description:
             "Periodic email digest now includes top search keywords, revenue/orders summary, " <>
               "and ad spend breakdown by platform alongside existing traffic stats."
         },
         %{
           title: "Feature: GSC actionable data",
           description:
             "Search Keywords page now shows position distribution, ranking changes (7d vs prior 7d), " <>
               "CTR opportunities, and new/lost keywords. Anomaly detector checks SEO rankings and CTR."
         },
         %{
           title: "Fix: Dashboard chart performance",
           description:
             "90-day and 12-month views now use pre-aggregated daily_stats table instead of scanning raw events."
         }
       ]},
      {"v5.7.0", "2026-04-05T12:00:00Z",
       [
         %{
           title: "Feature: SOC2 security controls",
           description:
             "Password complexity (12+ chars, letter + number). Account lockout after 5 failed logins (15 min). " <>
               "Idle session timeout (30 min, opt-out available). Active session tracking (IP, user-agent). " <>
               "Admin force-logout. Forgot password with honeypot anti-abuse. Sign-in/out audit logging."
         },
         %{
           title: "Feature: Account-level MFA enforcement",
           description:
             "Platform admin can require 2FA for all users in an account. Users without 2FA are redirected " <>
               "to the setup page on login. 2FA verification sets a 12-hour session flag."
         },
         %{
           title: "Feature: Integration sync logging",
           description:
             "All sync operations (Stripe, Braintree, GSC, Bing, ad platforms) now log to the Integration " <>
               "Log page with event type, status, duration, and error details. Filterable by type."
         },
         %{
           title: "Feature: Yesterday toggle on dashboard",
           description:
             "New 'Yesterday' button in the date range selector shows previous full day's data."
         },
         %{
           title: "Fix: Integration data isolation",
           description:
             "Clear Data now properly scoped per platform. Search data filtered by source (Google/Bing). " <>
               "Ad spend filtered by platform. Bing Webmaster site URL configurable during setup."
         },
         %{
           title: "Fix: Ad sync frequency",
           description:
             "Google Ads and Meta Ads now respect per-integration sync frequency (was hardcoded 6h). " <>
               "Cron checks every 5 min, should_sync? gates based on configured interval."
         },
         %{
           title: "Fix: Realtime page shows state/region",
           description:
             "Realtime visitors now display city, state/region, country instead of just city, country."
         }
       ]},
      {"v5.6.0", "2026-04-03T12:00:00Z",
       [
         %{
           title: "Feature: Multi-tenant account system",
           description:
             "Account-based isolation for serving multiple customers. Each account has its own users, sites, " <>
               "and data boundary. Platform admin role manages all accounts. Superadmin manages their account. " <>
               "Per-account site limits. New /platform section for global management."
         },
         %{
           title: "Fix: MRR sidebar highlight",
           description:
             "Revenue & Subscriptions page now correctly highlights in the sidebar navigation."
         },
         %{
           title: "Fix: Removed debug output from Search Keywords page",
           description:
             "Removed ClickHouse row count debug line that was visible on the Search Keywords page."
         },
         %{
           title: "Fix: Compilation warnings cleaned up",
           description:
             "Fixed duplicate @doc attributes, unused imports, unused variables, and input name=\"id\" " <>
               "warnings across integration status, integration log, settings, sites, and ClickHouse modules."
         }
       ]},
      {"v5.5.0", "2026-04-04T12:00:00Z",
       [
         %{
           title: "Feature: Google Search Console & Bing Webmaster integration",
           description:
             "New Search Keywords page under Acquisition showing organic search queries, impressions, " <>
               "clicks, CTR, and average position. Google Search Console via OAuth2, Bing Webmaster via API key. " <>
               "Data syncs daily (2-3 day delay for GSC). Sortable columns, source filter (Google/Bing/All), " <>
               "date range selector, top pages by search, position color-coding."
         },
         %{
           title: "Feature: Ecommerce source filtering",
           description:
             "When Stripe is connected, revenue dashboards automatically show only Stripe data (pi_* orders). " <>
               "API transactions are still collected but not displayed — prevents double-counting."
         }
       ]},
      {"v5.4.0", "2026-04-03T12:00:00Z",
       [
         %{
           title: "Feature: Braintree payment integration",
           description:
             "Connect Braintree from Site Settings to import transactions, refunds, and subscriptions. " <>
               "Same capabilities as Stripe: automatic revenue attribution, customer LTV, MRR tracking, " <>
               "refund adjustments. Uses Braintree's XML search API with Basic auth (Merchant ID + Public/Private keys)."
         },
         %{
           title: "Feature: Configurable sync frequency per integration",
           description:
             "Each connected integration (Stripe, Braintree, Google Ads, Bing, Meta) now has its own sync " <>
               "frequency dropdown: 5 min, 15 min, 30 min, 1 hour, 6 hours, or 24 hours. " <>
               "Default: 15 min for payment providers, 6 hours for ad platforms. " <>
               "Stored per-integration in the extra config map."
         }
       ]},
      {"v5.3.0", "2026-04-03T12:00:00Z",
       [
         %{
           title: "Feature: MRR & Subscription tracking from Stripe",
           description:
             "New dashboard page under Conversions showing current MRR, active subscriptions, " <>
               "plan breakdown, average MRR per subscriber, past due count, recent cancellations (30d), " <>
               "and MRR trend chart (30d). Powered by daily Stripe subscription snapshots."
         },
         %{
           title: "Feature: Customer LTV on visitor profiles",
           description:
             "Visitor profile pages now show a Lifetime Value card with net revenue (gross minus refunds), " <>
               "total order count, refund total, and first/last purchase dates. " <>
               "Appears automatically for visitors with ecommerce events."
         },
         %{
           title: "Feature: Stripe refund tracking",
           description:
             "Stripe sync now fetches refunds and updates the refund_amount on the matching charge. " <>
               "Net revenue (gross - refunds) used in LTV calculations and Revenue Attribution. " <>
               "Partial refunds supported."
         },
         %{
           title: "UX: Currency symbols on all revenue values",
           description:
             "Revenue displays now use proper currency symbols ($, \u20AC, \u00A3, etc.) instead of " <>
               "currency codes. Format: $100.00 instead of 100.00 USD."
         }
       ]},
      {"v5.2.0", "2026-04-03T12:00:00Z",
       [
         %{
           title: "Feature: Stripe charge import",
           description:
             "Connect Stripe from Site Settings to automatically import completed charges as ecommerce events. " <>
               "Charges matched to identified visitors via email lookup. Syncs every 6h (today + yesterday). " <>
               "Deduplicates by charge_id. All existing Revenue Attribution, Revenue Cohorts, Buyer Patterns, " <>
               "and ROAS dashboards work automatically — zero additional instrumentation needed."
         }
       ]},
      {"v5.1.0", "2026-04-03T12:00:00Z",
       [
         %{
           title: "UX: Dashboard defaults to Today view",
           description:
             "Overview dashboard now loads with 'Today' as the default time range instead of '7d'. " <>
               "Shows current-day activity immediately on page load."
         },
         %{
           title: "UX: Filter value dropdowns for categorical fields",
           description:
             "Segment filter value input now shows a dropdown for categorical fields: " <>
               "IP Country, Country Name, Browser, OS, Device Type, Visitor Intent, and Event Type. " <>
               "Options are populated from actual site data (last 90 days). Free-text input remains for other fields."
         }
       ]},
      {"v5.0.0", "2026-04-03T12:00:00Z",
       [
         %{
           title: "Feature: Multi-tenant account system",
           description:
             "Accounts entity for grouping sites and users. Platform admin role for global management. " <>
               "Superadmins are now account-level owners who manage their own sites and team. " <>
               "Complete isolation between customer accounts. Configurable per-account site limits (default 10). " <>
               "New /platform routes for global administration (accounts, ingest, spam filter, API logs). " <>
               "Existing /admin routes scoped to account context. Migration backfills all existing data into Vianet account."
         },
         %{
           title: "New role: platform_admin",
           description:
             "Platform admin sees all accounts, sites, and users across the entire platform. " <>
               "Can create new accounts, invite superadmins, and configure site limits. " <>
               "Superadmins can now invite other superadmins to co-manage their account."
         }
       ]},
      {"v4.10.0", "2026-04-03T12:00:00Z",
       [
         %{
           title: "Fix: First/last touch attribution returning zero",
           description:
             "Revenue Attribution first-touch and last-touch models returned empty results because the " <>
               "subquery JOIN timed out on large event tables. Restructured into two parallel flat queries " <>
               "(visitor counts + revenue scoped to purchasing visitors) merged in Elixir. " <>
               "Any-touch model was unaffected and remains unchanged."
         },
         %{
           title: "Fix: Reverse proxy IP forwarding",
           description:
             "Added X-Spectabas-Real-IP trusted header for proxied requests. Render's load balancer " <>
               "overwrites X-Forwarded-For on the second hop, causing all proxied visitors to share " <>
               "the proxy server's IP. The custom header bypasses this, preserving real client IPs for " <>
               "geo enrichment and visitor dedup."
         },
         %{
           title: "Update: Proxy setup guide — endpoint.ex + Cloudflare WAF",
           description:
             "Proxy plug must go in endpoint.ex (before Plug.Parsers), not router.ex — prevents " <>
               "CSRF 403 errors and body consumption. Added Cloudflare WAF exception step — Bot Fight Mode " <>
               "serves JS challenges that sendBeacon cannot solve, blocking all tracking beacons."
         }
       ]},
      {"v4.9.0", "2026-04-02T12:00:00Z",
       [
         %{
           title: "Security: Audit v4 — 5 findings fixed",
           description:
             "IP extraction priority reversed (X-Forwarded-For before CF-Connecting-IP to prevent spoofing). " <>
               "Hardcoded utility endpoint token replaced with UTILITY_TOKEN env var. " <>
               "CollectPayload field length limits on fingerprint/click ID fields. " <>
               "Segment LIKE wildcard injection escaped. Click ID format validation (5-256 chars, alphanumeric)."
         }
       ]},
      {"v4.8.0", "2026-04-02T12:00:00Z",
       [
         %{
           title: "Feature: Site-configurable visitor intent classification",
           description:
             "Intent classifier now reads per-site path configuration from Settings. New 'engaging' intent " <>
               "for core app features (search, listings, messaging). Lowered researching threshold to 2 pages. " <>
               "Returning visitors detected regardless of referrer. Pre-configured for all active sites."
         },
         %{
           title: "Feature: Intent configuration UI in Site Settings",
           description:
             "Customize buying, engaging, and support path patterns per site. Set researching threshold. " <>
               "Paths matched as fragments (e.g. '/listings' matches '/listings/123')."
         }
       ]},
      {"v4.7.0", "2026-04-02T12:00:00Z",
       [
         %{
           title: "Feature: Enhanced dashboard pages with richer metrics",
           description:
             "Entry Pages now shows bounce rate and avg duration. Exit Pages shows avg duration. " <>
               "Events shows sessions and avg per visitor. Goals shows unique completers and conversion rate. " <>
               "Campaigns shows 30-day traffic stats (visitors, sessions, bounce rate) per campaign."
         }
       ]},
      {"v4.6.0", "2026-04-02T12:00:00Z",
       [
         %{
           title: "Feature: Consolidated Acquisition page",
           description:
             "Merged All Channels, Sources, and Channel Attribution into a single Acquisition page. " <>
               "Channels view shows engagement metrics (bounce rate, avg duration, pages/session) with drill-down. " <>
               "Sources view has referrer + 5 UTM tabs. Old URLs redirect to the new page."
         },
         %{
           title: "Fix: Visitor Quality calculations (bounce rate, return rate, duration)",
           description:
             "Bounce rate used is_bounce column that was never set by ingest (always 100%). Restructured as 3-level " <>
               "session-based query. Return rate was always 100% (identity division). Duration excluded visitors " <>
               "with no duration events, inflating average."
         },
         %{
           title: "Fix: Meta Ads JSON response parsing across all endpoints",
           description:
             "Meta Graph API returns raw JSON strings instead of parsed maps. Added ensure_parsed/1 helper " <>
               "on all 4 endpoints: token exchange, refresh, account fetch, and daily spend sync."
         },
         %{
           title: "Fix: Ad spend sync no longer creates duplicate rows",
           description:
             "Yesterday's data now only synced once per UTC day. Today's partial data synced every 6h. " <>
               "Eliminates need for periodic OPTIMIZE TABLE FINAL."
         },
         %{
           title: "UI: Distinct ad platform pill colors",
           description:
             "Google Ads blue, Bing Ads amber, Meta Ads purple — updated across 6 pages."
         },
         %{
           title: "UI: Clickable page URLs on Buyer Patterns",
           description:
             "Page paths now link to the actual page on the tracked site with an external link icon."
         },
         %{
           title: "UI: Revenue Cohorts explainer text",
           description: "Added explanation of how cohort rows and columns work."
         }
       ]},
      {"v4.5.0", "2026-04-02T12:00:00Z",
       [
         %{
           title:
             "Fix: Ad spend sync numbers incorrect (missing FINAL on ReplacingMergeTree queries)",
           description:
             "All 5 ad_spend queries now use FINAL keyword to deduplicate rows from repeated 6-hour syncs. " <>
               "Without FINAL, ClickHouse summed duplicate rows causing inflated/stale spend totals."
         },
         %{
           title: "Fix: Meta Ads and Bing Ads missing account ID during OAuth setup",
           description:
             "Meta and Bing callbacks now fetch ad accounts after token exchange and show an account picker " <>
               "(matching existing Google Ads flow). Previously saved empty account_id, causing API errors."
         },
         %{
           title: "Fix: Revenue Attribution channel cards showing blank labels",
           description:
             "Channel attribution query used argMinIf which returns empty string (not NULL) when no signal events exist. " <>
               "Added nullIf wrapper so visitors with no signal are correctly labeled 'Direct'."
         },
         %{
           title: "Fix: Empty account_id guard on all ad platform spend fetchers",
           description:
             "Meta and Bing fetch_daily_spend now return a clear error message when account_id is missing, " <>
               "matching the existing Google Ads guard."
         }
       ]},
      {"v4.4.0", "2026-04-02T12:00:00Z",
       [
         %{
           title: "Feature: Enhanced Insights with revenue, ad traffic, and churn detection",
           description:
             "Insights page now detects 8 types of anomalies: traffic changes, bounce rate shifts, source changes, " <>
               "page drops, high exit rates, revenue changes, ad traffic shifts (new platforms detected, volume changes), " <>
               "and customer churn risk spikes. Each insight includes severity, metrics, and actionable recommendations."
         },
         %{
           title: "Feature: Category landing pages for all 7 dashboard sections",
           description:
             "Each sidebar category (Overview, Behavior, Acquisition, Audience, Conversions, Ad Effectiveness, Tools) " <>
               "has a hub page with card grid linking to each page with detailed descriptions. Sidebar labels are clickable."
         },
         %{
           title: "Feature: Breadcrumbs on all dashboard pages",
           description:
             "Site Name / Category / Page Title breadcrumb trail on every page. Category link goes to category landing page. Colors match sidebar sections."
         },
         %{
           title: "Feature: Revenue Attribution — sortable columns + paid/organic split",
           description:
             "All columns sortable (click header to toggle). Source table splits rows by paid vs organic with colored pills " <>
               "(Google Ads blue, Bing Ads cyan, Meta Ads indigo). Works across all UTM tabs."
         },
         %{
           title: "Fix: All 5 Ad Effectiveness queries rewritten for ClickHouse performance",
           description:
             "Replaced CTE-based queries with flat GROUP BY. Fixed column name mismatches (9 total), " <>
               "ORDER BY bugs, and groupArray syntax. Added bloom_filter skip index on click_id."
         },
         %{
           title: "Fix: Self-referral filtering in Revenue Attribution queries",
           description:
             "Revenue Attribution source and channel queries now exclude the site's own domain. " <>
               "Historical data with www.roommates.com as source now correctly resolves to Direct."
         },
         %{
           title: "Feature: Reverse proxy (data-proxy) for ad blocker evasion",
           description:
             "Tracker supports data-proxy attribute to route beacons through the main domain. " <>
               "Setup guide email with Phoenix plug code, Cloudflare notes, and simplified snippet."
         }
       ]},
      {"v4.3.1", "2026-04-01T12:00:00Z",
       [
         %{
           title: "Feature: Ad platform integrations — Sync Now, account picker, API fixes",
           description:
             "Settings page: Sync Now button, first-sync status. Google Ads: v17→v23, MCC account picker. " <>
               "Meta: v21→v25. Bing: v13 confirmed, async reporting rewrite. Full adapter audit with error details."
         },
         %{
           title: "Feature: Click ID attribution (gclid/msclkid/fbclid) + ROAS",
           description:
             "Tracker captures ad click IDs from URLs. ClickHouse click_id/click_id_type columns. " <>
               "Revenue Attribution: ad spend overview, per-platform ROAS, any-touch model. " <>
               "Visitor profiles: click ID + full UTM data. Realtime: ad platform pills. 20 new tests."
         },
         %{
           title: "Feature: 5 Ad Effectiveness pages",
           description:
             "Visitor Quality (0-100 scoring), Time to Convert (days to purchase), Ad Visitor Paths, " <>
               "Ad-to-Churn (campaign churn correlation), Organic Lift (ad spend vs organic traffic). " <>
               "9 analytics queries, new sidebar section."
         },
         %{
           title: "Fix: Fingerprint entropy, self-referral filtering, docs markdown",
           description:
             "Added AudioContext/WebGL/font fingerprint signals. Self-referral filtering in queries. " <>
               "All docs markdown fixed (numbered lists, links, italics). New Conversions docs category. " <>
               "Click ID diagnostics on ingest page."
         },
         %{
           title: "Feature: ROAS + ad spend on Revenue Attribution page",
           description:
             "Revenue Attribution now shows ad spend data from all connected platforms (Google Ads, Bing, Meta). " <>
               "Ad Spend Overview card with total spend, revenue, ROAS, clicks, impressions, and per-platform breakdown. " <>
               "Campaign tab shows inline Spend, ROAS, and CPC columns merged with revenue data. " <>
               "Standalone Ad Spend by Campaign table on other tabs with CPC and CTR. ROAS color-coded (green 3x+, yellow 1-3x, red <1x)."
         },
         %{
           title: "Feature: Google Ads account picker",
           description:
             "When connecting Google Ads with multiple accounts under a manager (MCC), shows an account selection page with descriptive names instead of auto-picking the first one."
         },
         %{
           title: "Fix: Full ad platform adapter audit",
           description:
             "Google Ads: parse string metric values (costMicros, clicks, impressions) instead of assuming integers. " <>
               "Bing Ads: rewrote to use correct async submit/poll/download reporting flow (was using non-existent sync endpoint). " <>
               "Meta Ads: show real API error messages on settings page. All adapters now surface detailed errors."
         }
       ]},
      {"v4.3.0", "2026-04-01T12:00:00Z",
       [
         %{
           title: "Feature: Ad platform integrations (Google Ads, Bing, Meta)",
           description:
             "Connect Google Ads, Microsoft/Bing Ads, and Meta/Facebook Ads accounts via OAuth2. Daily ad spend data (spend, clicks, impressions by campaign) synced every 6 hours. Encrypted token storage. ROAS calculation on Revenue Attribution page. Env vars: GOOGLE_ADS_CLIENT_ID/SECRET/DEVELOPER_TOKEN, BING_ADS_CLIENT_ID/SECRET/DEVELOPER_TOKEN, META_ADS_APP_ID/SECRET."
         }
       ]},
      {"v4.2.0", "2026-04-01T12:00:00Z",
       [
         %{
           title: "Enhancement: Revenue Attribution overhaul",
           description:
             "All 5 UTM dimensions (Source, Medium, Campaign, Term, Content). First-touch vs last-touch attribution toggle. Channel summary cards (Direct, Organic, Paid, Social, Referral, Email). Revenue share bars per source. 90-day date range option."
         }
       ]},
      {"v4.1.0", "2026-04-01T12:00:00Z",
       [
         %{
           title: "Feature: granular site access for Analyst/Viewer roles",
           description:
             "Admins can now control which sites each Analyst and Viewer can access from the Users admin page. Click 'Configure' next to any non-admin user to toggle site access with one click. Superadmin and Admin roles retain access to all sites."
         }
       ]},
      {"v4.0.0", "2026-04-01T12:00:00Z",
       [
         %{
           title: "Feature: Revenue Attribution",
           description:
             "New dashboard page showing which traffic sources generate paying customers. Tracks visitors → orders → revenue → conversion rate by source, campaign, or medium."
         },
         %{
           title: "Feature: Revenue Cohorts",
           description:
             "Customer lifetime value analysis. Groups customers by first-purchase week and tracks revenue per customer over time in a cohort heatmap."
         },
         %{
           title: "Feature: Buyer Patterns",
           description:
             "Compares buyer vs non-buyer behavior. Shows pages where buyers over-index (lift analysis) and side-by-side engagement stats (sessions, pages, duration)."
         },
         %{
           title: "Feature: Churn Risk",
           description:
             "Identifies customers with declining engagement (fewer sessions, fewer pages in last 14 days vs prior 14 days). Shows risk level, email for identified customers, and links to visitor profiles."
         },
         %{
           title: "Feature: Funnel revenue + abandoned export",
           description:
             "Funnels now show revenue from visitors who reached each step (for ecommerce-enabled sites). Each step has an 'Export drop-off' button that downloads a CSV of visitor IDs and emails who abandoned at that step."
         }
       ]},
      {"v3.7.0", "2026-04-01T12:00:00Z",
       [
         %{
           title: "Feature: Matomo historical data import",
           description:
             "Imported ~5.3M historical events from Matomo covering April 2025 through March 2026 for roommates.com. Admin endpoint with import, status, and rollback actions. All imported data identifiable by 'imported_' visitor ID prefix for safe rollback."
         }
       ]},
      {"v3.6.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Feature: ecommerce product categories",
           description:
             "Items in ecommerce transactions now support an optional `category` field (e.g. \"new_subscription\" vs \"renewal\"). Top Products table groups by name + category with category badges. Item summaries on orders show category in parentheses."
         }
       ]},
      {"v3.5.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Fix: bounce rate calculation",
           description:
             "Bounce rate now uses the industry-standard definition: sessions with exactly 1 pageview. Previously, duration events and custom events incorrectly disqualified sessions from being bounces, resulting in artificially low bounce rates (~11% vs the expected ~45%)."
         }
       ]},
      {"v3.4.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Feature: API key scopes/restrictions UI",
           description:
             "API key creation form now includes scope checkboxes (read:stats, read:visitors, write:events, write:identify, admin:sites), site restriction checkboxes, and optional expiry date. Key list displays scopes, site restrictions, and expiry status with color-coded badges."
         }
       ]},
      {"v3.3.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Feature: user timezone preference",
           description:
             "Admin pages (ingest diagnostics, API logs) now include a timezone picker. All timestamps display in the chosen timezone. Preference is saved to user profile."
         },
         %{
           title: "Fix: all dashboard timestamps now use site timezone",
           description:
             "Fixed 11 ClickHouse queries that returned raw UTC timestamps. Visitor log, visitor profiles, ecommerce orders, realtime feed, and all cross-reference pages now display times in the site's configured timezone."
         },
         %{
           title: "Fix: visitor unique constraint race condition",
           description:
             "Concurrent event ingestion no longer crashes on duplicate visitor inserts. Added unique_constraint declarations, insert-conflict retry, and best-effort fingerprint updates."
         }
       ]},
      {"v3.2.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Feature: email on ecommerce transactions",
           description:
             "The ecommerce transaction API now accepts an optional `email` field. When provided, it identifies the visitor and links the transaction to their Spectabas profile. Orders table shows email instead of truncated visitor ID."
         }
       ]},
      {"v3.1.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Feature: ecommerce stats on main dashboard",
           description:
             "Sites with ecommerce enabled now show revenue, orders, and average order value cards on the main overview dashboard."
         },
         %{
           title: "Feature: identified users count",
           description:
             "Main dashboard shows how many visitors have been identified (associated with an email) and what percentage of total visitors that represents."
         },
         %{
           title: "Feature: ecommerce revenue chart",
           description:
             "Ecommerce page now includes a combined bar/line chart showing daily revenue (bars) and order count (line) over the selected period."
         }
       ]},
      {"v3.0.1", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Fix: visitor dedup in cookie mode",
           description:
             "In GDPR-off (cookie) mode, new cookies no longer merge visitors by fingerprint. New cookie = new visitor. Fingerprint-based dedup is now only used in GDPR-on (cookieless) mode."
         }
       ]},
      {"v3.0.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Feature: API token scopes",
           description:
             "Granular permission scopes on API keys: read:stats, read:visitors, write:events, write:identify, admin:sites. Tokens can be restricted to specific sites with optional expiry dates."
         },
         %{
           title: "Feature: API access logging",
           description:
             "Every API call is logged with request/response bodies. 30-day retention. Admin UI at /admin/api-logs with detail modal for inspecting individual requests."
         },
         %{
           title: "Feature: ingest diagnostics dashboard",
           description:
             "New /admin/ingest page shows live BEAM memory, buffer size, ETS visitor cache stats, and ClickHouse connection pool metrics."
         }
       ]},
      {"v2.9.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Performance: high-throughput ingest pipeline",
           description:
             "Async flush, 1000 batch size (up from default), ETS-based visitor cache, dedicated ClickHouse connection pool (100 connections), and per-site rate limiting at 1000 events/sec."
         }
       ]},
      {"v2.8.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Feature: occurred_at timestamp on all events",
           description:
             "All API endpoints and the JavaScript tracker now support an optional occurred_at field (Unix UTC seconds) to backdate events up to 7 days. Useful for server-side event queuing and batch imports."
         },
         %{
           title: "Fix: ClickHouse outage no longer crashes the BEAM",
           description:
             "IngestBuffer flush now wraps ClickHouse inserts in try/rescue so connection failures are logged and dead-lettered instead of crashing the process."
         }
       ]},
      {"v2.7.1", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Fix: ecommerce dashboard crash",
           description:
             "Fixed internal server error caused by string vs atom key mismatch, missing top products query, and format_money not handling string values."
         },
         %{
           title: "API: ecommerce read + write endpoints",
           description:
             "GET stats, products, orders at /api/v1/sites/:id/ecommerce/*. POST transactions at /api/v1/sites/:id/ecommerce/transactions for server-side order recording."
         },
         %{
           title: "Fix: ecommerce_order events now write to ecommerce_events table",
           description:
             "IngestBuffer now extracts ecommerce_order events from the batch and writes them to the ecommerce_events ClickHouse table alongside the main events table."
         }
       ]},
      {"v2.7.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "API: server-side visitor identification",
           description:
             "New POST /api/v1/sites/:id/identify endpoint. Link email addresses to anonymous visitors from your server when users log in. Read the _sab cookie and send it with the email."
         },
         %{
           title: "Fix: client-side identify was broken",
           description:
             "The /c/i endpoint was passing site_id as the visitor lookup key instead of using cookie_id + site_id. Now correctly looks up visitors by cookie_id scoped to the site."
         }
       ]},
      {"v2.6.1", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Fix: funnel_stats now scoped to date range",
           description:
             "Funnel queries were scanning the entire events table. Now filtered by timestamp."
         },
         %{
           title: "Fix: goal_completions excludes bot traffic",
           description: "Bot visitors no longer inflate conversion numbers."
         },
         %{
           title: "Fix: cohort retention sizes corrected",
           description:
             "Cohort size calculation was always returning 1 per cohort due to incorrect GROUP BY. Now properly counts visitors per cohort week."
         },
         %{
           title: "Security: origin bypass closed",
           description:
             "Requests with sec-fetch-site header (browsers) now require valid Origin or Referer. Server-side collection still works without headers."
         },
         %{
           title: "Security: session cookie hardened",
           description:
             "Endpoint session key and salt now match runtime config. Added secure and http_only flags."
         },
         %{
           title: "Fix: cross-domain tokens now work",
           description:
             "destination_allowed? was parsing bare hostnames as URIs (always nil). Now treats destination as plain hostname."
         },
         %{
           title: "Fix: SPA duration attributed to correct page",
           description:
             "Duration events now use the URL of the page visited, not the URL after SPA navigation."
         },
         %{
           title: "Fix: timezone_distribution counts only pageviews",
           description:
             "Was counting all event types as pageviews. Now uses countIf for accuracy."
         },
         %{
           title: "Fix: dashboard crash on ClickHouse timeout",
           description:
             "empty_overview now returns atom keys matching fetch_overview, preventing crashes when queries time out."
         }
       ]},
      {"v2.6.0", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Security: SQL injection fix in visitor log pagination",
           description: "per_page parameter is now parameterized and clamped to 1-200 range."
         },
         %{
           title: "Security: saved segment IDOR fix",
           description:
             "Loading saved segments now validates ownership by user and site, preventing cross-user segment access."
         },
         %{
           title: "Security: origin validation on identify and cross-domain endpoints",
           description:
             "/c/i and /c/x now check request origin and opt-out cookies, matching /c/e protections."
         },
         %{
           title: "Fix: ingest error handling",
           description:
             "Ingest.process errors are now properly logged instead of silently swallowed as crashes."
         },
         %{
           title: "Performance: parallel deferred stats loading",
           description:
             "Dashboard deferred stats (9 queries) now run in parallel via Task.async instead of sequentially, reducing load time by ~5x."
         }
       ]},
      {"v2.5.5", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Fix: datacenter IPs no longer auto-flagged as bots",
           description:
             "VPN, corporate proxy, and cloud-hosted browser visitors were being permanently excluded from all analytics. Bot flag now only comes from UA detection."
         },
         %{
           title: "Fix: broken SQL in public dashboard overview_stats",
           description:
             "ip_is_bot filter was placed after GROUP BY instead of in the WHERE clause, causing incorrect visitor counts on shared dashboards."
         },
         %{
           title: "Fix: origin check allows all subdomains",
           description:
             "Events from non-www subdomains (e.g. app.example.com) were being rejected. Now any subdomain of the parent domain is allowed."
         },
         %{
           title: "Improvement: tracker retries on server error",
           description:
             "Failed event sends (e.g. during backpressure 503) are now retried once after 2 seconds."
         },
         %{
           title: "Improvement: realtime visitor list increased to 100",
           description:
             "Realtime visitor grouped view was capped at 30 results, missing active visitors. Increased to 100."
         }
       ]},
      {"v2.5.4", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Fix: SPA pageview overcounting",
           description:
             "Query-string-only URL changes (search filters, pagination, sorting) no longer trigger separate pageviews. Only pathname changes count as new pageviews, matching standard analytics behavior."
         },
         %{
           title: "API: realtime visitor details endpoint",
           description:
             "New GET /api/v1/sites/:id/realtime/visitors returns grouped visitor details (browser, OS, country, current page) for the last 5 minutes."
         }
       ]},
      {"v2.5.3", "2026-03-31T12:00:00Z",
       [
         %{
           title: "Fix: snippet now includes data-gdpr and data-xd attributes",
           description:
             "The tracking snippet shown in site settings now includes data-gdpr=\"off\" when GDPR mode is disabled, and data-xd when cross-domain sites are configured. Previously these attributes were always omitted, causing the tracker to default to fingerprint-only mode regardless of settings."
         },
         %{
           title: "Fix: health check no longer requires ClickHouse",
           description:
             "The /health endpoint now returns 200 as long as Postgres is reachable. ClickHouse starting asynchronously no longer causes deploy failures."
         }
       ]},
      {"v2.5.2", "2026-03-28T12:00:00Z",
       [
         %{
           title: "Fix: page load times on Top Pages",
           description:
             "RUM vitals query now caps page_load at 60s (filtering corrupt data from old NaN bug) and returns data for the most-visited pages instead of the slowest, so load times actually appear next to top pages."
         }
       ]},
      {"v2.5.1", "2026-03-28T12:00:00Z",
       [
         %{
           title: "Performance: parallel realtime queries",
           description:
             "realtime dashboard now runs all 3 ClickHouse queries concurrently using Task.async with 10s timeout and safe fallbacks."
         },
         %{
           title: "Performance: response compression",
           description:
             "dynamic HTML and JSON responses are now gzip-compressed for clients that support it, reducing bandwidth for dashboard pages."
         },
         %{
           title: "Performance: keyset pagination for visitor log",
           description:
             "replaced OFFSET-based pagination with cursor/keyset pagination for stable, efficient browsing of large visitor sets."
         },
         %{
           title: "Performance: bounded email report queries",
           description:
             "email report subscription lookups now pre-filter in SQL (excluding recently-sent subscriptions) to reduce database load."
         },
         %{
           title: "Performance: streamed data exports",
           description:
             "large CSV exports now fetch and write data in 10,000-row chunks instead of loading all rows into memory at once."
         },
         %{
           title: "Reliability: ingest buffer backpressure",
           description:
             "collection endpoint now returns 503 when the ingest buffer exceeds 5,000 events, preventing memory exhaustion under extreme load. Tracker handles 503 gracefully."
         }
       ]},
      {"v2.5.0", "2026-03-30T12:00:00Z",
       [
         %{
           title: "IP Profile page",
           description:
             "dedicated page for any IP address showing geo details (city, country, org, ASN, timezone), datacenter/VPN/Tor/bot/EU badges, all visitors who used the IP (linked to profiles), and top pages visited from that IP. Accessible from visitor log search, visitor profiles, and direct URL."
         },
         %{
           title: "Zoomable visitor map",
           description:
             "visitor map now has region preset buttons — World, N. America, S. America, Europe, Asia, Africa, Oceania, USA. Click to zoom the map to that region. Also made the map responsive (250px mobile, 350px tablet, 450px desktop)."
         }
       ]},
      {"v2.4.5", "2026-03-30T23:59:00Z",
       [
         %{
           title: "Fingerprint uniqueness fix",
           description:
             "restored full User-Agent string in fingerprint signals. Removing it (for stability) caused massive false merges — all users with the same device model, browser major version, screen size, and timezone shared one fingerprint. One 'visitor' was showing 50+ IP addresses. The full UA adds OS build, minor version, and patch info that differentiates otherwise-identical devices."
         }
       ]},
      {"v2.4.4", "2026-03-30T23:55:00Z",
       [
         %{
           title: "Device pie charts and percentages",
           description:
             "Devices page now shows a doughnut pie chart alongside the table. Each row includes a percentage column. Chart updates when switching tabs (Device Type, Browser, OS) or date range. Top 8 items shown in chart, all items in table."
         }
       ]},
      {"v2.4.3", "2026-03-30T23:45:00Z",
       [
         %{
           title: "Pageview rate limiting",
           description:
             "prevents overcounting from rapid page refreshes, auto-refresh, or iframe reloads. Uses sessionStorage to enforce a 5-second minimum interval between pageviews for the same URL. Fixes cases where a single visitor showed hundreds of views for one page in minutes."
         }
       ]},
      {"v2.4.2", "2026-03-30T23:30:00Z",
       [
         %{
           title: "IP Address Investigation Tools",
           description:
             "IP search results now show full geo info (city, country, org) with datacenter/VPN/bot badges. Visitor profiles show all IP addresses the visitor has used with location, org, event count, and last seen. Each IP links back to search. Clicking from IP search to a visitor profile preserves the searched IP context."
         }
       ]},
      {"v2.4.1", "2026-03-30T23:00:00Z",
       [
         %{
           title: "IP Address Search",
           description:
             "search visitors by IP address on the Visitor Log page. Enter any IP to find all visitors who used it, with links to full profiles. Also supports direct URL: /visitor-log?ip=x.x.x.x"
         },
         %{
           title: "System Diagnostics link",
           description:
             "added System Diagnostics card to the admin dashboard, linking to /health/diag for ClickHouse, Postgres, GeoIP, RUM, and visitor breakdown diagnostics."
         }
       ]},
      {"v2.4.0", "2026-03-30T22:00:00Z",
       [
         %{
           title: "Saved Segments",
           description:
             "Save, load, and manage segment filter presets. Current filter combinations can be saved with a name and reloaded instantly from the filter bar. Presets are per-user and per-site."
         },
         %{
           title: "Row Evolution Sparklines",
           description:
             "Click any row in the Pages table to expand an inline sparkline chart showing the pageview trend for that specific page over the selected time period. Uses Chart.js for rendering."
         }
       ]},
      {"v2.3.1", "2026-03-30T18:00:00Z",
       [
         %{
           title: "Spam Filter Admin Page",
           description:
             "admin page at /admin/spam-filter for managing referrer spam blocklist. Custom domains can be added/removed via DB. Auto-detection queries ClickHouse for suspicious referrer domains (high bot %, multi-site hits) and presents candidates for review. Daily Oban worker runs detection at 7am UTC. Builtin domains remain hardcoded."
         }
       ]},
      {"v2.3.0", "2026-03-30T15:00:00Z",
       [
         %{
           title: "Outbound Link Tracking",
           description:
             "auto-tracks clicks on external links — shows destination domains, full URLs, hit counts, and unique visitors. No code changes needed."
         },
         %{
           title: "File Download Tracking",
           description:
             "auto-tracks clicks on downloadable files (PDF, ZIP, DOC, XLS, CSV, MP3, MP4, etc.) with filename, URL, hits, and visitors."
         },
         %{
           title: "Custom Events Browser",
           description:
             "new Events page under Behavior showing all custom events fired via Spectabas.track(), with internal events hidden."
         },
         %{
           title: "Referrer Spam Filtering",
           description:
             "known spam domains (semalt.com, darodar.com, etc.) are automatically excluded from Sources and Channels analytics."
         }
       ]},
      {"v2.2.3", "2026-03-30T14:00:00Z",
       [
         %{
           title: "Bot Traffic page",
           description:
             "dedicated bot analysis under Audience: bot vs human event/visitor counts, bot percentage, breakdown by type (datacenter/VPN/Tor), most targeted pages by bots, and top bot user agent strings."
         }
       ]},
      {"v2.2.2", "2026-03-30T13:00:00Z",
       [
         %{
           title: "Consistent visitor/pageview counting across all pages",
           description:
             "added ip_is_bot=0 filter to 11 queries that were missing it: entry_pages, exit_pages, top_pages, visitor_locations, timezone_distribution, visitor_log, page_transitions totals, site_searches, overview_stats_public, intent_breakdown. Bot traffic excluded from all standard analytics views. Network page intentionally keeps bot stats for traffic quality analysis."
         }
       ]},
      {"v2.2.1", "2026-03-30T12:00:00Z",
       [
         %{
           title: "Channel drill-down + visitor count fix",
           description:
             "clicking a channel now shows its individual sources (e.g., Search Engines → google.com, bing.com). Fixed visitor overcounting — channel breakdown now uses SQL-level classification with uniq(visitor_id) per channel instead of summing across groups. Shared ClickHouse CASE expression for channel classification."
         }
       ]},
      {"v2.2.0", "2026-03-30T11:00:00Z",
       [
         %{
           title: "All Channels page",
           description:
             "new Acquisition page that automatically groups traffic into marketing channels — Search Engines, Social Networks, AI Assistants, Email, Paid Search, Paid Social, Websites, Direct, and Other Campaigns. Shows pageviews, visitors, sessions, and source count per channel."
         },
         %{
           title: "Sources page — 6 UTM tabs",
           description:
             "Sources page now has six tabs: Referrers, UTM Source, UTM Medium, UTM Campaign, UTM Term, UTM Content. Each UTM tab queries only entries with that parameter set (no blank rows). Blank UTMs no longer appear."
         },
         %{
           title: "Session overcounting fix",
           description:
             "top_sources query now uses uniq(session_id) from raw events instead of sum(sessions) from the SummingMergeTree MV, fixing overcounting across multi-day ranges."
         }
       ]},
      {"v2.1.1", "2026-03-29T19:00:00Z",
       [
         %{
           title: "Email Reports moved to own page",
           description:
             "email reports now have a dedicated page under Tools in the sidebar (was embedded in Settings). Shows schedule info — 'Sent every Monday' for weekly, '1st of each month' for monthly. Fixed save not persisting. Live preview updates schedule as you change frequency."
         }
       ]},
      {"v2.1.0", "2026-03-29T18:00:00Z",
       [
         %{
           title: "Email Reports",
           description:
             "configurable email report digests per site: daily, weekly, or monthly. Reports include pageview/visitor summary with period comparison, top 5 pages, sources, and countries. HTML emails with inline styles. Settings in site Settings page with frequency and send hour (in site timezone). One-click unsubscribe from email. Admin view shows all subscribers. Dispatched via Oban cron every 15 minutes with period-key idempotency."
         },
         %{
           title: "Competitive Analysis page",
           description:
             "internal strategy reference at /admin/competitive — feature gap matrix, unique advantages, positioning vs 7 competitors, 6-month roadmap, and market trends."
         }
       ]},
      {"v2.0.0", "2026-03-29T16:00:00Z",
       [
         %{
           title: "Resilience improvements — 10 fixes",
           description:
             "DeadLetterRetry now scheduled (events no longer lost on ClickHouse outages). IngestBuffer flushes on shutdown (no data loss on deploys), catches per-event errors (single bad event can't crash batch), dead-letters overflows instead of dropping. Pixel endpoint has try/rescue. Dashboard uses Task.yield (no more LiveView crashes on timeout). Unique constraints on visitors table (prevents race condition duplicates). ClickHouse errors now include query SQL. Dead letter queue monitoring alerts when queue grows."
         }
       ]},
      {"v1.9.3", "2026-03-29T15:00:00Z",
       [
         %{
           title: "Fix RUM page_load/dom_complete always NaN — wrong API property",
           description:
             "Root cause: the tracker used nav.navigationStart which doesn't exist on PerformanceNavigationTiming (the modern API). It only exists on the deprecated performance.timing. So nav.loadEventEnd - undefined = NaN for page_load, dom_complete, and dom_interactive. Fixed by using nav.startTime (which is 0 for navigation entries) instead of nav.navigationStart. TTFB/FCP/DNS worked because they subtract from other PerformanceNavigationTiming properties, not navigationStart."
         }
       ]},
      {"v1.9.2", "2026-03-29T14:00:00Z",
       [
         %{
           title: "Fix RUM dashboard showing 0 — ClickHouse nan crashes JSON parser",
           description:
             "Root cause: ClickHouse quantileIf returns 'nan' in JSONEachRow when no rows match the condition. 'nan' is not valid JSON, causing Jason.decode! to crash. The crash was caught by safe_query's rescue clause, which returned an empty map — so the dashboard showed 0 samples. Fixed by sanitizing ClickHouse responses: nan→null and inf→null before JSON parsing. Also filters NaN values in tracker's mapToStrings to avoid storing 'NaN' strings."
         }
       ]},
      {"v1.9.1", "2026-03-28T02:05:00Z",
       [
         %{
           title: "Fix RUM page load metrics always showing 0",
           description:
             "Root cause: the tracker's polling-based RUM scheduling (500ms to 8s polls + 10s force-send) created a race condition on heavy pages. When loadEventEnd was still 0 at the 10s force timeout, the tracker sent TTFB/FCP without page_load and set rumSent=true, blocking the load event handler (which fires at 12-20s on WordPress sites) from ever sending complete data. Fixed by replacing polling with event-driven triggers: load event as primary trigger (with 500ms delay for loadEventEnd to populate), visibilitychange as safety net for early departures, and a 30s final fallback. DOM Ready, Full Load, Median Load, and P75 Load now correctly appear on the Performance dashboard."
         }
       ]},
      {"v1.9.0", "2026-03-29T08:00:00Z",
       [
         %{
           title: "Code quality refactoring",
           description:
             "extracted shared TypeHelpers (to_num, to_float, format_ms, format_duration, format_number) and DateHelpers (range_to_period) modules — eliminated 200+ lines of duplication across 20 files. Fixed attribution crash on 90d range (was returning {:custom, 90} tuple). Added bot filtering to 5 more queries (transitions, attribution, cohort, map, search). Added @moduledoc to all 27 dashboard LiveViews."
         }
       ]},
      {"v1.8.1", "2026-03-29T07:00:00Z",
       [
         %{
           title: "Fingerprint accuracy improvements",
           description:
             "64-bit hash (two MurmurHash3 with different seeds) reduces collision probability from ~50% at 77K visitors to ~50% at 5 billion. Browser family + major version replaces full UA string in fingerprint signals — minor browser updates no longer rotate fingerprints."
         },
         %{
           title: "CLS session window method",
           description:
             "CLS now uses Google's recommended session window approach (max session with 1s gap, capped at 5s) instead of cumulative total. Aligns with web-vitals library methodology. Prevents over-reporting CLS on long-lived pages."
         },
         %{
           title: "Ecommerce currency safety",
           description:
             "Revenue queries now filter to the site's configured currency, preventing different currencies from being summed together. Orders with mismatched currency are excluded from totals."
         }
       ]},
      {"v1.8.0", "2026-03-29T06:00:00Z",
       [
         %{
           title: "Data accuracy fixes — 8 issues",
           description:
             "Site Search fixed (was querying external referrer URLs instead of internal page URLs). Bot traffic now filtered from all analytics queries (ip_is_bot=0). Unique visitor counts reverted from materialized views to raw events (MVs were overcounting across multi-day ranges). Bounce rate now considers custom events (active visitors with 1 pageview no longer counted as bounces). UTMs extracted before GDPR URL stripping (were being lost in GDPR-on mode). Duration tracks foreground time instead of wall-clock (no more background-tab inflation). URL paths normalized (lowercase, trailing slash stripped). SPA duplicate pageviews prevented (URL-change check before sending)."
         }
       ]},
      {"v1.7.1", "2026-03-29T05:00:00Z",
       [
         %{
           title: "Materialized views for analytics queries",
           description:
             "7 analytics queries now use pre-aggregated ClickHouse materialized views instead of scanning raw events: top_sources → source_stats, top_countries/top_regions/top_countries_summary → country_stats, top_devices/top_browsers/top_os/top_device_types → device_stats. These views are SummingMergeTree tables that aggregate on INSERT, making queries 10-100x faster for large datasets. Network stats stays on raw events (needs EU flag not in materialized view)."
         }
       ]},
      {"v1.7.0", "2026-03-29T04:00:00Z",
       [
         %{
           title: "Performance optimizations",
           description:
             "site lookup cache now covers public_key (eliminates 1 Postgres query per event). UA parsed once instead of 2-3x. Session extend uses single UPDATE instead of SELECT+UPDATE. Dashboard mount queries run in parallel (2-3x faster). Your Sites page uses single batched ClickHouse query instead of N+1. PubSub events no longer trigger ClickHouse queries. Dead letter uses bulk insert. Session cleanup uses batch UPDATE. ClickHouse gets bloom filter indexes on event_type, event_name, url_path. Req structs stored in persistent_term instead of Agent."
         }
       ]},
      {"v1.6.3", "2026-03-29T03:00:00Z",
       [
         %{
           title: "RUM: collect all metrics reliably",
           description:
             "fixed bug where sending TTFB early set rumSent=true, preventing page_load/dom_complete from ever being captured. Now polls for loadEventEnd at 0.5s, 1.5s, 3s, 5s, 8s intervals — only sends once page_load is ready. Force-sends on visibilitychange (visitor leaving) or 10s timeout with whatever metrics are available. One event per page load, complete data."
         }
       ]},
      {"v1.6.2", "2026-03-29T02:00:00Z",
       [
         %{
           title: "Mobile UI improvements",
           description:
             "44px touch targets on mobile nav icons and dashboard nav items. Scroll indicator gradient on horizontally scrollable nav bar. Visitor Log hides Device and Entry columns on mobile (6→4 visible columns). Segment filter form stacks vertically on phones. Docs page gets mobile jump-to-section dropdown. Text contrast upgraded from gray-400 to gray-500 across all 14 dashboard pages for WCAG AA compliance. Log out link hidden on mobile (accessible via Account page)."
         }
       ]},
      {"v1.6.1", "2026-03-29T01:00:00Z",
       [
         %{
           title: "RUM collection reliability fix",
           description:
             "RUM data no longer requires the load event to fire — sends immediately when TTFB is available (100ms after script load). Fixes RUM not collecting on heavy WordPress/Elementor sites where visitors leave before the load event fires. Missing metrics (page_load, dom_complete) are excluded server-side via quantileIf. Script cache reduced from 24h to 1h for faster tracker updates."
         }
       ]},
      {"v1.6.0", "2026-03-29T00:00:00Z",
       [
         %{
           title: "Security audit v2 — 10 findings fixed",
           description:
             "WebAuthn binary_to_term now uses :safe option (prevents code execution). Passkey deletion requires user ownership. Pixel endpoint respects opt-out cookie (GDPR regression fixed). Origin validation no longer bypassed when Origin header is empty. API custom date ranges capped at 12 months. Default ClickHouse passwords removed from config. CSP adds object-src 'none'. Remember-me cookie gets secure + http_only flags. Health endpoint no longer leaks internal architecture. Backfill-geo uses param/1 for all interpolated values."
         }
       ]},
      {"v1.5.2", "2026-03-28T18:00:00Z",
       [
         %{
           title: "Timezone-aware dashboard",
           description:
             "all date boundaries now respect your site's configured timezone. \"Today\" shows midnight-to-now in local time. \"24h\" is a true rolling 24-hour window. Chart bucket labels use proper timezone conversion (replaces approximate offset table, handles DST correctly). \"Your Sites\" overview uses each site's timezone for today's stats."
         },
         %{
           title: "\"Today\" preset button",
           description:
             "new time period option on the site dashboard showing today's traffic from midnight in your site's timezone, with hourly chart bars starting at 00:00."
         },
         %{
           title: "RUM collection reliability",
           description:
             "replaced requestIdleCallback with load event listener for reliable RUM collection. Added performance.timing fallback for broader browser support. CWV now sent via three triggers (5s delay, visibilitychange, 10s fallback) to ensure data isn't lost."
         }
       ]},
      {"v1.5.1", "2026-03-28T12:00:00Z",
       [
         %{
           title: "RUM accuracy fixes",
           description:
             "fixed 0ms readings for page load, DOM ready, and FID. Tracker now waits for loadEventEnd before collecting navigation timing, retries up to 5 times. CWV sent on visibilitychange for accurate final values. Queries use quantileIf to exclude zero/empty values. FID correctly omitted when no user interaction occurred."
         },
         %{
           title: "Per-page performance in Pages & Transitions",
           description:
             "Pages table now shows a color-coded load time pill (green/amber/red) for each page. Transitions page shows Load, LCP, and FCP stats for the analyzed page. Quick reference without leaving the page you're on."
         }
       ]},
      {"v1.5.0", "2026-03-27T12:00:00Z",
       [
         %{
           title: "Real User Monitoring (RUM)",
           description:
             "measures actual page load times and Core Web Vitals (LCP, CLS, FID) from real visitor browsers. Zero performance impact — uses requestIdleCallback and PerformanceObserver APIs. New Performance dashboard page shows: Core Web Vitals with Good/Needs Work/Poor scoring per Google thresholds, page load timing breakdown (TTFB, FCP, DOM Ready, Full Load), performance by device type, and slowest pages ranked by median load time."
         }
       ]},
      {"v1.4.0", "2026-03-29T12:00:00Z",
       [
         %{
           title: "Insights & Anomaly Alerts",
           description:
             "automated analysis comparing last 7 days vs prior 7 days. Detects: traffic drops/spikes, bounce rate increases, referrer sources gained/lost, page traffic drops, high exit rate pages. Color-coded severity (alert/warning/notice/info) with actionable recommendations."
         },
         %{
           title: "Visitor Journey Mapping",
           description:
             "shows the most common multi-step paths visitors take through the site. Each journey is a sequence of page pills with arrows. Conversion pages highlighted in green. Stats: total sessions, multi-page sessions, avg pages/session, converting sessions."
         }
       ]},
      {"v1.3.3", "2026-03-29T11:00:00Z",
       [
         %{
           title: "Time period controls moved back to main content",
           description:
             "date presets (24h/7d/30d/90d/12m) and compare toggle back in main content area, accessible on all screen sizes. Removed from sidebar."
         },
         %{
           title: "Mobile dashboard improvements",
           description:
             "responsive stat cards (smaller text/padding on mobile), shorter chart height (192px mobile, 280px desktop), smaller intent icons, responsive map height, tighter spacing"
         }
       ]},
      {"v1.3.2", "2026-03-29T10:00:00Z",
       [
         %{
           title: "Fix: complete visitor deduplication rewrite",
           description:
             "server now checks cookie THEN fingerprint before creating visitors. Cookie-lost visitors matched by fingerprint and existing record updated with new cookie. Cookies-blocked visitors fall back to fingerprint as ID. Single-phase fingerprint eliminates split IDs."
         }
       ]},
      {"v1.3.1", "2026-03-29T09:00:00Z",
       [
         %{
           title: "Fix: visitor deduplication — cookie + fingerprint",
           description:
             "eliminated two-phase fingerprint (was creating split visitor IDs). Fixed cookie SameSite=None→Lax (None silently fails on HTTP). Single consistent fingerprint computed once on page load. Cookie now persists correctly on both HTTP and HTTPS sites."
         }
       ]},
      {"v1.3.0", "2026-03-29T08:00:00Z",
       [
         %{
           title: "Mobile navigation overhaul",
           description:
             "top navbar: text links hidden on mobile, replaced with icon buttons (dashboard, docs, account). Dashboard sidebar: two-row mobile nav — quick access to top 5 pages + scrollable full navigation bar with all 19 pages. Active page highlighted in both rows."
         }
       ]},
      {"v1.2.3", "2026-03-29T07:00:00Z",
       [
         %{
           title: "Fix: invited users can now log in with password",
           description:
             "invitation acceptance was only saving the email (email_changeset) but not hashing the password. Now uses register_user_with_password which applies both email and password changesets."
         },
         %{
           title: "Fix: use client fingerprint for dedup",
           description:
             "tracker sends stable canvas/WebGL fingerprint (_fp) in every beacon. Server uses client fingerprint instead of rotating server-generated one for visitor dedup."
         },
         %{
           title: "New test: verify invited user can log in",
           description:
             "end-to-end test that invitation acceptance creates a user who can authenticate with their password. Also tests email mismatch rejection."
         }
       ]},
      {"v1.2.2", "2026-03-29T06:00:00Z",
       [
         %{
           title: "Fix visitor dedup: use client browser fingerprint",
           description:
             "tracker now sends _fp (canvas/WebGL fingerprint) in every beacon. Server uses client fingerprint for dedup instead of server-generated UA+IP+date which rotated daily. GDPR-on mode also prefers client fingerprint. Both modes now store the stable fingerprint for future matching."
         }
       ]},
      {"v1.2.1", "2026-03-29T05:00:00Z",
       [
         %{
           title: "Visitor deduplication via fingerprint",
           description:
             "GDPR-off visitors who lose their cookie are now matched by browser fingerprint to their existing visitor record. Prevents duplicate visitor counts. Also stores fingerprint on first cookie-based visit for future dedup."
         }
       ]},
      {"v1.2.0", "2026-03-29T04:00:00Z",
       [
         %{
           title: "Grouped realtime visitors",
           description:
             "realtime page now shows 'Active Visitors' view (one row per visitor with current page, pageviews, location, device, intent, last activity) and 'Event Feed' view (raw events). Auto-refreshes every 5 seconds."
         },
         %{
           title: "Browser fingerprint in visitor profiles",
           description:
             "fingerprint hash displayed in Identity & Device card with count of other visitors sharing the same fingerprint"
         }
       ]},
      {"v1.1.1", "2026-03-29T03:00:00Z",
       [
         %{
           title: "Tracker performance optimization",
           description:
             "zero-blocking fingerprint: quick sync fingerprint (~0.1ms) fires with first beacon, enhanced fingerprint (canvas+WebGL) runs async 50ms later. Canvas hashes raw pixels instead of base64 toDataURL. Removed broken AudioContext (was async but result never captured). Form abuse listeners deferred 100ms. URL parsing skipped when no xd token. UTM parsing skipped when no utm_ in query string. ~9KB minified, ~3KB gzipped."
         }
       ]},
      {"v1.1.0", "2026-03-29T02:00:00Z",
       [
         %{
           title: "Enhanced browser fingerprinting",
           description:
             "canvas, WebGL, AudioContext, and 15+ browser signals combined into a stable hash. Survives cookie clearing, incognito, and VPN. Stored per event for cross-session correlation."
         },
         %{
           title: "Form abuse detection",
           description:
             "tracker monitors form submissions, paste events, and rapid clicks. Fires _form_abuse custom event when suspicious patterns detected."
         },
         %{
           title: "Fingerprint cross-referencing",
           description:
             "visitor profiles show other visitors with the same browser fingerprint — detects alt accounts, ban evasion, shared devices."
         }
       ]},
      {"v1.0.1", "2026-03-29T01:00:00Z",
       [
         %{
           title: "205 automated tests",
           description:
             "added WebAuthn, intent classifier (14 cases), security (SQL injection, null bytes, segment validation), and updated docs"
         }
       ]},
      {"v1.0.0", "2026-03-29T00:00:00Z",
       [
         %{
           title: "WebAuthn/Passkey 2FA support",
           description:
             "register security keys (Bitwarden, 1Password, YubiKey, device passkeys) as a second factor. Manage keys in Account Settings."
         },
         %{
           title: "Admin: Force 2FA per user",
           description:
             "admins can toggle 'Force 2FA' on individual users in the admin users page. Required/Optional toggle with amber badge."
         },
         %{
           title: "API key management + 2FA setup in settings",
           description: "generate, view, revoke API keys. 2FA status and setup link."
         }
       ]},
      {"v0.9.1", "2026-03-28T23:30:00Z",
       [
         %{
           title: "API key management in Account Settings",
           description:
             "generate, view, and revoke API keys directly from the settings page. Key shown once on creation."
         },
         %{
           title: "2FA setup link in Account Settings",
           description:
             "shows 2FA status (enabled/disabled) and link to set up TOTP authenticator"
         }
       ]},
      {"v0.9.0", "2026-03-28T23:00:00Z",
       [
         %{
           title: "Raw user-agent string storage",
           description:
             "user_agent column added to ClickHouse events. Full UA string displayed in visitor profiles for debugging."
         },
         %{
           title: "Mobile responsiveness",
           description:
             "all tables horizontally scrollable on mobile, mobile nav bar with back button and quick links, page header hidden on mobile (shown in nav bar instead)"
         }
       ]},
      {"v0.8.0", "2026-03-28T22:00:00Z",
       [
         %{
           title: "Security audit: 10 findings fixed",
           description:
             "Critical: diagnostic endpoints now require admin auth. High: opt-out cookie now respected. Medium: login rate limiting, invitation email verification, TOTP rate limits, buffer overflow protection, visitor_id validation, ClickHouse 2-year TTL, MMDB integrity checks, null byte sanitization."
         }
       ]},
      {"v0.7.0", "2026-03-28T21:00:00Z",
       [
         %{
           title: "Visitor intent icons and cross-linking",
           description:
             "FontAwesome SVG icons for each intent category, clickable to filter visitor log. Intent pill added to visitor log table."
         },
         %{
           title: "Enhanced realtime feed",
           description:
             "shows visitor ID (clickable to profile), location (to geo), browser (to devices), referrer (to visitor log), and page path (to transitions)"
         },
         %{
           title: "Color-coded sidebar categories",
           description:
             "Overview=indigo, Behavior=blue, Acquisition=emerald, Audience=amber, Conversions=rose, Tools=gray"
         },
         %{
           title: "Docs page scroll navigation",
           description: "clicking a topic in the sidebar now scrolls to that section"
         }
       ]},
      {"v0.6.1", "2026-03-28T20:30:00Z",
       [
         %{
           title: "Accessible top navigation bar",
           description:
             "light background, larger text (text-sm), higher contrast (gray-600 on white), ARIA roles and labels, taller bar (h-14), focus ring on sign-in button"
         }
       ]},
      {"v0.6.0", "2026-03-28T20:00:00Z",
       [
         %{
           title: "Documentation page",
           description:
             "comprehensive searchable docs at /docs covering all dashboard pages, tracker installation, JS API, REST API, GDPR config, campaigns, goals, and administration"
         },
         %{
           title: "Invitation workflow improvements",
           description: "resend deletes prior pending invitations, added revoke button"
         }
       ]},
      {"v0.5.1", "2026-03-28T19:15:00Z",
       [
         %{
           title: "Invitation workflow improvements",
           description:
             "Resending an invite now deletes prior pending invitations for the same email. Added Revoke button with confirmation to delete pending invitations."
         }
       ]},
      {"v0.5.0", "2026-03-28T18:30:00Z",
       [
         %{
           title: "Timezone-aware charts",
           description:
             "24h timeseries chart now displays hours in the site's configured timezone instead of UTC"
         },
         %{
           title: "Changelog page",
           description: "versioned changelog with timestamps accessible from admin panel"
         },
         %{
           title: "Audit log fix",
           description: "user_id now properly extracted and displayed in audit entries"
         },
         %{
           title: "Updated CLAUDE.md and README",
           description: "comprehensive developer guide and project documentation"
         }
       ]},
      {"v0.4.0", "2026-03-28T15:00:00Z",
       [
         %{
           title: "Visitor Intent Detection",
           description:
             "automatic classification of visitors by behavior (buying, researching, comparing, support, returning, browsing, bot)"
         },
         %{
           title: "MaxMind GeoLite2 Integration",
           description: "timezone enrichment, EU flag detection"
         },
         %{
           title: "Cross-linking between analytics pages",
           description: "clickable dimensions navigate to filtered views"
         },
         %{
           title: "Sidebar navigation layout",
           description: "persistent sidebar on all dashboard pages with categorized navigation"
         },
         %{
           title: "Efficiency audit fixes",
           description: "async dashboard loading, batched queries, optimized caching"
         },
         %{
           title: "182 automated tests",
           description: "covering all major functionality"
         },
         %{
           title: "Comprehensive visitor profiles",
           description: "with IP cross-referencing"
         },
         %{
           title:
             "Segmentation, visitor log, page transitions, attribution, site search, cohort retention",
           description: nil
         }
       ]},
      {"v0.1.0", "2026-03-27T12:00:00Z",
       [
         %{
           title: "Initial launch of Spectabas analytics platform",
           description: nil
         },
         %{
           title: "JavaScript tracker with ad-blocker evasion",
           description: nil
         },
         %{
           title: "ClickHouse event storage",
           description: "with real-time ingestion"
         },
         %{
           title: "Bot detection",
           description: "UA + client-side + datacenter IP"
         },
         %{
           title: "GeoIP enrichment",
           description: "with state/city resolution"
         },
         %{
           title: "Dashboard with time-series charts (Chart.js)",
           description: "visitor map, top pages/sources/states"
         },
         %{
           title: "Custom date range picker",
           description: "with period comparison"
         },
         %{
           title: "Entry/exit pages analysis",
           description: nil
         },
         %{
           title: "Self-referrer filtering",
           description: nil
         },
         %{
           title: "Cloudflare CF-Connecting-IP support",
           description: nil
         },
         %{
           title: "Invitation system",
           description: "with email delivery"
         },
         %{
           title: "Role-based access control",
           description: "superadmin, admin, analyst, viewer"
         }
       ]}
    ]
  end
end
