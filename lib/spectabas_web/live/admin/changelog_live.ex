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
