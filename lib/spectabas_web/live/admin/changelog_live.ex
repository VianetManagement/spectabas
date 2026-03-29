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
