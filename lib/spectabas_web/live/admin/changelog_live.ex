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
        <div :for={{date, items} <- @entries}>
          <h2 class="text-lg font-semibold text-gray-900 border-b border-gray-200 pb-2 mb-4">
            {date}
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

  defp entries do
    [
      {"v2.2.1 — 2026-03-30 12:00 UTC",
       [
         %{
           title: "Channel drill-down + visitor count fix",
           description:
             "clicking a channel now shows its individual sources (e.g., Search Engines → google.com, bing.com). Fixed visitor overcounting — channel breakdown now uses SQL-level classification with uniq(visitor_id) per channel instead of summing across groups. Shared ClickHouse CASE expression for channel classification."
         }
       ]},
      {"v2.2.0 — 2026-03-28 12:00 UTC",
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
      {"v2.1.1 — 2026-03-29 19:00 UTC",
       [
         %{
           title: "Email Reports moved to own page",
           description:
             "email reports now have a dedicated page under Tools in the sidebar (was embedded in Settings). Shows schedule info — 'Sent every Monday' for weekly, '1st of each month' for monthly. Fixed save not persisting. Live preview updates schedule as you change frequency."
         }
       ]},
      {"v2.1.0 — 2026-03-29 18:00 UTC",
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
      {"v2.0.0 — 2026-03-29 16:00 UTC",
       [
         %{
           title: "Resilience improvements — 10 fixes",
           description:
             "DeadLetterRetry now scheduled (events no longer lost on ClickHouse outages). IngestBuffer flushes on shutdown (no data loss on deploys), catches per-event errors (single bad event can't crash batch), dead-letters overflows instead of dropping. Pixel endpoint has try/rescue. Dashboard uses Task.yield (no more LiveView crashes on timeout). Unique constraints on visitors table (prevents race condition duplicates). ClickHouse errors now include query SQL. Dead letter queue monitoring alerts when queue grows."
         }
       ]},
      {"v1.9.3 — 2026-03-29 15:00 UTC",
       [
         %{
           title: "Fix RUM page_load/dom_complete always NaN — wrong API property",
           description:
             "Root cause: the tracker used nav.navigationStart which doesn't exist on PerformanceNavigationTiming (the modern API). It only exists on the deprecated performance.timing. So nav.loadEventEnd - undefined = NaN for page_load, dom_complete, and dom_interactive. Fixed by using nav.startTime (which is 0 for navigation entries) instead of nav.navigationStart. TTFB/FCP/DNS worked because they subtract from other PerformanceNavigationTiming properties, not navigationStart."
         }
       ]},
      {"v1.9.2 — 2026-03-29 14:00 UTC",
       [
         %{
           title: "Fix RUM dashboard showing 0 — ClickHouse nan crashes JSON parser",
           description:
             "Root cause: ClickHouse quantileIf returns 'nan' in JSONEachRow when no rows match the condition. 'nan' is not valid JSON, causing Jason.decode! to crash. The crash was caught by safe_query's rescue clause, which returned an empty map — so the dashboard showed 0 samples. Fixed by sanitizing ClickHouse responses: nan→null and inf→null before JSON parsing. Also filters NaN values in tracker's mapToStrings to avoid storing 'NaN' strings."
         }
       ]},
      {"v1.9.1 — 2026-03-28 02:05 UTC",
       [
         %{
           title: "Fix RUM page load metrics always showing 0",
           description:
             "Root cause: the tracker's polling-based RUM scheduling (500ms to 8s polls + 10s force-send) created a race condition on heavy pages. When loadEventEnd was still 0 at the 10s force timeout, the tracker sent TTFB/FCP without page_load and set rumSent=true, blocking the load event handler (which fires at 12-20s on WordPress sites) from ever sending complete data. Fixed by replacing polling with event-driven triggers: load event as primary trigger (with 500ms delay for loadEventEnd to populate), visibilitychange as safety net for early departures, and a 30s final fallback. DOM Ready, Full Load, Median Load, and P75 Load now correctly appear on the Performance dashboard."
         }
       ]},
      {"v1.9.0 — 2026-03-29 08:00 UTC",
       [
         %{
           title: "Code quality refactoring",
           description:
             "extracted shared TypeHelpers (to_num, to_float, format_ms, format_duration, format_number) and DateHelpers (range_to_period) modules — eliminated 200+ lines of duplication across 20 files. Fixed attribution crash on 90d range (was returning {:custom, 90} tuple). Added bot filtering to 5 more queries (transitions, attribution, cohort, map, search). Added @moduledoc to all 27 dashboard LiveViews."
         }
       ]},
      {"v1.8.1 — 2026-03-29 07:00 UTC",
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
      {"v1.8.0 — 2026-03-29 06:00 UTC",
       [
         %{
           title: "Data accuracy fixes — 8 issues",
           description:
             "Site Search fixed (was querying external referrer URLs instead of internal page URLs). Bot traffic now filtered from all analytics queries (ip_is_bot=0). Unique visitor counts reverted from materialized views to raw events (MVs were overcounting across multi-day ranges). Bounce rate now considers custom events (active visitors with 1 pageview no longer counted as bounces). UTMs extracted before GDPR URL stripping (were being lost in GDPR-on mode). Duration tracks foreground time instead of wall-clock (no more background-tab inflation). URL paths normalized (lowercase, trailing slash stripped). SPA duplicate pageviews prevented (URL-change check before sending)."
         }
       ]},
      {"v1.7.1 — 2026-03-29 05:00 UTC",
       [
         %{
           title: "Materialized views for analytics queries",
           description:
             "7 analytics queries now use pre-aggregated ClickHouse materialized views instead of scanning raw events: top_sources → source_stats, top_countries/top_regions/top_countries_summary → country_stats, top_devices/top_browsers/top_os/top_device_types → device_stats. These views are SummingMergeTree tables that aggregate on INSERT, making queries 10-100x faster for large datasets. Network stats stays on raw events (needs EU flag not in materialized view)."
         }
       ]},
      {"v1.7.0 — 2026-03-29 04:00 UTC",
       [
         %{
           title: "Performance optimizations",
           description:
             "site lookup cache now covers public_key (eliminates 1 Postgres query per event). UA parsed once instead of 2-3x. Session extend uses single UPDATE instead of SELECT+UPDATE. Dashboard mount queries run in parallel (2-3x faster). Your Sites page uses single batched ClickHouse query instead of N+1. PubSub events no longer trigger ClickHouse queries. Dead letter uses bulk insert. Session cleanup uses batch UPDATE. ClickHouse gets bloom filter indexes on event_type, event_name, url_path. Req structs stored in persistent_term instead of Agent."
         }
       ]},
      {"v1.6.3 — 2026-03-29 03:00 UTC",
       [
         %{
           title: "RUM: collect all metrics reliably",
           description:
             "fixed bug where sending TTFB early set rumSent=true, preventing page_load/dom_complete from ever being captured. Now polls for loadEventEnd at 0.5s, 1.5s, 3s, 5s, 8s intervals — only sends once page_load is ready. Force-sends on visibilitychange (visitor leaving) or 10s timeout with whatever metrics are available. One event per page load, complete data."
         }
       ]},
      {"v1.6.2 — 2026-03-29 02:00 UTC",
       [
         %{
           title: "Mobile UI improvements",
           description:
             "44px touch targets on mobile nav icons and dashboard nav items. Scroll indicator gradient on horizontally scrollable nav bar. Visitor Log hides Device and Entry columns on mobile (6→4 visible columns). Segment filter form stacks vertically on phones. Docs page gets mobile jump-to-section dropdown. Text contrast upgraded from gray-400 to gray-500 across all 14 dashboard pages for WCAG AA compliance. Log out link hidden on mobile (accessible via Account page)."
         }
       ]},
      {"v1.6.1 — 2026-03-29 01:00 UTC",
       [
         %{
           title: "RUM collection reliability fix",
           description:
             "RUM data no longer requires the load event to fire — sends immediately when TTFB is available (100ms after script load). Fixes RUM not collecting on heavy WordPress/Elementor sites where visitors leave before the load event fires. Missing metrics (page_load, dom_complete) are excluded server-side via quantileIf. Script cache reduced from 24h to 1h for faster tracker updates."
         }
       ]},
      {"v1.6.0 — 2026-03-29 00:00 UTC",
       [
         %{
           title: "Security audit v2 — 10 findings fixed",
           description:
             "WebAuthn binary_to_term now uses :safe option (prevents code execution). Passkey deletion requires user ownership. Pixel endpoint respects opt-out cookie (GDPR regression fixed). Origin validation no longer bypassed when Origin header is empty. API custom date ranges capped at 12 months. Default ClickHouse passwords removed from config. CSP adds object-src 'none'. Remember-me cookie gets secure + http_only flags. Health endpoint no longer leaks internal architecture. Backfill-geo uses param/1 for all interpolated values."
         }
       ]},
      {"v1.5.2 — 2026-03-28 18:00 UTC",
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
      {"v1.5.1 — 2026-03-28 12:00 UTC",
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
      {"v1.5.0 — 2026-03-27 12:00 UTC",
       [
         %{
           title: "Real User Monitoring (RUM)",
           description:
             "measures actual page load times and Core Web Vitals (LCP, CLS, FID) from real visitor browsers. Zero performance impact — uses requestIdleCallback and PerformanceObserver APIs. New Performance dashboard page shows: Core Web Vitals with Good/Needs Work/Poor scoring per Google thresholds, page load timing breakdown (TTFB, FCP, DOM Ready, Full Load), performance by device type, and slowest pages ranked by median load time."
         }
       ]},
      {"v1.4.0 — 2026-03-29 12:00 UTC",
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
      {"v1.3.3 — 2026-03-29 11:00 UTC",
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
      {"v1.3.2 — 2026-03-29 10:00 UTC",
       [
         %{
           title: "Fix: complete visitor deduplication rewrite",
           description:
             "server now checks cookie THEN fingerprint before creating visitors. Cookie-lost visitors matched by fingerprint and existing record updated with new cookie. Cookies-blocked visitors fall back to fingerprint as ID. Single-phase fingerprint eliminates split IDs."
         }
       ]},
      {"v1.3.1 — 2026-03-29 09:00 UTC",
       [
         %{
           title: "Fix: visitor deduplication — cookie + fingerprint",
           description:
             "eliminated two-phase fingerprint (was creating split visitor IDs). Fixed cookie SameSite=None→Lax (None silently fails on HTTP). Single consistent fingerprint computed once on page load. Cookie now persists correctly on both HTTP and HTTPS sites."
         }
       ]},
      {"v1.3.0 — 2026-03-29 08:00 UTC",
       [
         %{
           title: "Mobile navigation overhaul",
           description:
             "top navbar: text links hidden on mobile, replaced with icon buttons (dashboard, docs, account). Dashboard sidebar: two-row mobile nav — quick access to top 5 pages + scrollable full navigation bar with all 19 pages. Active page highlighted in both rows."
         }
       ]},
      {"v1.2.3 — 2026-03-29 07:00 UTC",
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
      {"v1.2.2 — 2026-03-29 06:00 UTC",
       [
         %{
           title: "Fix visitor dedup: use client browser fingerprint",
           description:
             "tracker now sends _fp (canvas/WebGL fingerprint) in every beacon. Server uses client fingerprint for dedup instead of server-generated UA+IP+date which rotated daily. GDPR-on mode also prefers client fingerprint. Both modes now store the stable fingerprint for future matching."
         }
       ]},
      {"v1.2.1 — 2026-03-29 05:00 UTC",
       [
         %{
           title: "Visitor deduplication via fingerprint",
           description:
             "GDPR-off visitors who lose their cookie are now matched by browser fingerprint to their existing visitor record. Prevents duplicate visitor counts. Also stores fingerprint on first cookie-based visit for future dedup."
         }
       ]},
      {"v1.2.0 — 2026-03-29 04:00 UTC",
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
      {"v1.1.1 — 2026-03-29 03:00 UTC",
       [
         %{
           title: "Tracker performance optimization",
           description:
             "zero-blocking fingerprint: quick sync fingerprint (~0.1ms) fires with first beacon, enhanced fingerprint (canvas+WebGL) runs async 50ms later. Canvas hashes raw pixels instead of base64 toDataURL. Removed broken AudioContext (was async but result never captured). Form abuse listeners deferred 100ms. URL parsing skipped when no xd token. UTM parsing skipped when no utm_ in query string. ~9KB minified, ~3KB gzipped."
         }
       ]},
      {"v1.1.0 — 2026-03-29 02:00 UTC",
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
      {"v1.0.1 — 2026-03-29 01:00 UTC",
       [
         %{
           title: "205 automated tests",
           description:
             "added WebAuthn, intent classifier (14 cases), security (SQL injection, null bytes, segment validation), and updated docs"
         }
       ]},
      {"v1.0.0 — 2026-03-29 00:00 UTC",
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
      {"v0.9.1 — 2026-03-28 23:30 UTC",
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
      {"v0.9.0 — 2026-03-28 23:00 UTC",
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
      {"v0.8.0 — 2026-03-28 22:00 UTC",
       [
         %{
           title: "Security audit: 10 findings fixed",
           description:
             "Critical: diagnostic endpoints now require admin auth. High: opt-out cookie now respected. Medium: login rate limiting, invitation email verification, TOTP rate limits, buffer overflow protection, visitor_id validation, ClickHouse 2-year TTL, MMDB integrity checks, null byte sanitization."
         }
       ]},
      {"v0.7.0 — 2026-03-28 21:00 UTC",
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
      {"v0.6.1 — 2026-03-28 20:30 UTC",
       [
         %{
           title: "Accessible top navigation bar",
           description:
             "light background, larger text (text-sm), higher contrast (gray-600 on white), ARIA roles and labels, taller bar (h-14), focus ring on sign-in button"
         }
       ]},
      {"v0.6.0 — 2026-03-28 20:00 UTC",
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
      {"v0.5.1 — 2026-03-28 19:15 UTC",
       [
         %{
           title: "Invitation workflow improvements",
           description:
             "Resending an invite now deletes prior pending invitations for the same email. Added Revoke button with confirmation to delete pending invitations."
         }
       ]},
      {"v0.5.0 — 2026-03-28 18:30 UTC",
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
      {"v0.4.0 — 2026-03-28 15:00 UTC",
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
      {"v0.1.0 — 2026-03-27",
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
