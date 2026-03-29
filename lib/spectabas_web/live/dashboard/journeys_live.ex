defmodule SpectabasWeb.Dashboard.JourneysLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites}
  alias Spectabas.Analytics.JourneyMapper
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Visitor Journeys - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_atom(range)

    journeys =
      case JourneyMapper.top_journeys(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    stats =
      case JourneyMapper.journey_stats(site, user, period) do
        {:ok, s} -> s
        _ -> %{}
      end

    socket
    |> assign(:journeys, journeys)
    |> assign(:stats, stats)
  end

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Visitor Journeys"
      page_description="Most common paths visitors take through your site. Shows which routes lead to conversions."
      active="journeys"
      live_visitors={0}
    >
      <div class="max-w-5xl mx-auto px-3 sm:px-6 lg:px-8 py-6">
        <%!-- Time range --%>
        <div class="flex items-center gap-2 mb-6">
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7 days"}, {"30d", "30 days"}]}
              phx-click="change_range"
              phx-value-range={elem(r, 0)}
              class={[
                "px-3 py-1.5 text-sm font-medium rounded-md",
                if(@date_range == elem(r, 0),
                  do: "bg-white shadow text-gray-900",
                  else: "text-gray-600 hover:text-gray-900"
                )
              ]}
            >
              {elem(r, 1)}
            </button>
          </nav>
        </div>

        <%!-- Journey stats --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Total Sessions</dt>
            <dd class="mt-1 text-xl font-bold text-gray-900">{@stats["total_sessions"] || 0}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Multi-Page Sessions</dt>
            <dd class="mt-1 text-xl font-bold text-gray-900">{@stats["multi_page_sessions"] || 0}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Avg Pages/Session</dt>
            <dd class="mt-1 text-xl font-bold text-gray-900">
              {@stats["avg_pages_per_session"] || 0}
            </dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Converting Sessions</dt>
            <dd class="mt-1 text-xl font-bold text-green-600">
              {@stats["converting_sessions"] || 0}
            </dd>
          </div>
        </div>

        <%!-- Journey list --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="font-semibold text-gray-900">Top Visitor Paths</h3>
            <p class="text-xs text-gray-500 mt-0.5">
              Most common page sequences (2+ pages per session)
            </p>
          </div>
          <div :if={@journeys == []} class="px-5 py-8 text-center text-gray-500">
            Not enough multi-page sessions yet.
          </div>
          <div :if={@journeys != []} class="divide-y divide-gray-50">
            <div :for={{journey, idx} <- Enum.with_index(@journeys)} class="px-5 py-4">
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <div class="flex items-center gap-1.5 text-sm font-medium text-gray-900 mb-1">
                    <span class="text-gray-400 text-xs">#{idx + 1}</span>
                    <span :if={journey.ends_at_conversion} class="text-green-600 text-xs">
                      &#10003;
                    </span>
                  </div>
                  <%!-- Journey path visualization --%>
                  <div class="flex items-center flex-wrap gap-1">
                    <span
                      :for={{page, pi} <- Enum.with_index(journey.pages)}
                      class="flex items-center gap-1"
                    >
                      <.link
                        navigate={~p"/dashboard/sites/#{@site.id}/transitions?page=#{page}"}
                        class={[
                          "px-2 py-1 rounded text-xs font-mono",
                          if(page == journey.conversion_page,
                            do: "bg-green-100 text-green-800 font-medium",
                            else: "bg-gray-100 text-gray-700 hover:bg-indigo-50 hover:text-indigo-700"
                          )
                        ]}
                      >
                        {page}
                      </.link>
                      <span :if={pi < length(journey.pages) - 1} class="text-gray-300 text-xs">
                        &rarr;
                      </span>
                    </span>
                  </div>
                </div>
                <div class="text-right shrink-0">
                  <div class="text-sm font-bold text-gray-900">{journey.visitors}</div>
                  <div class="text-xs text-gray-500">visitors</div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
