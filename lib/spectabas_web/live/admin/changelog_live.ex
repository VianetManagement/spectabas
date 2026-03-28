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
