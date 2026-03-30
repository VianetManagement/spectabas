defmodule SpectabasWeb.Dashboard.BotTrafficLive do
  @moduledoc "Bot traffic analysis — volume, sources, targeted pages, and user agents."

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Bot Traffic - #{site.name}")
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
    period = range_to_period(range)

    stats = safe_query(fn -> Analytics.bot_stats(site, user, period) end, %{})
    top_pages = safe_query(fn -> Analytics.bot_top_pages(site, user, period) end)
    top_uas = safe_query(fn -> Analytics.bot_top_user_agents(site, user, period) end)

    socket
    |> assign(:stats, stats)
    |> assign(:top_pages, top_pages)
    |> assign(:top_uas, top_uas)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Bot Traffic"
      page_description="Automated traffic analysis — bots, crawlers, scrapers, and datacenter traffic."
      active="bot-traffic"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Bot Traffic</h1>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"24h", "24h"}, {"7d", "7 days"}, {"30d", "30 days"}]}
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

        <%!-- Overview Stats --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <div class="bg-white rounded-lg shadow p-5">
            <div class="text-xs font-medium text-gray-500 uppercase">Bot Events</div>
            <div class="text-2xl font-bold text-red-600 mt-1">
              {format_number(to_num(@stats["bot_events"]))}
            </div>
            <div class="text-xs text-gray-500 mt-1">
              {to_num(@stats["bot_pct"])}% of all traffic
            </div>
          </div>
          <div class="bg-white rounded-lg shadow p-5">
            <div class="text-xs font-medium text-gray-500 uppercase">Bot Visitors</div>
            <div class="text-2xl font-bold text-red-600 mt-1">
              {format_number(to_num(@stats["bot_visitors"]))}
            </div>
            <div class="text-xs text-gray-500 mt-1">
              vs {format_number(to_num(@stats["human_visitors"]))} human
            </div>
          </div>
          <div class="bg-white rounded-lg shadow p-5">
            <div class="text-xs font-medium text-gray-500 uppercase">Human Events</div>
            <div class="text-2xl font-bold text-green-600 mt-1">
              {format_number(to_num(@stats["human_events"]))}
            </div>
            <div class="text-xs text-gray-500 mt-1">
              {100 - to_num(@stats["bot_pct"])}% of all traffic
            </div>
          </div>
          <div class="bg-white rounded-lg shadow p-5">
            <div class="text-xs font-medium text-gray-500 uppercase">Bot Types</div>
            <div class="mt-2 space-y-1">
              <div class="flex justify-between text-sm">
                <span class="text-gray-600">Datacenter</span>
                <span class="font-medium">{format_number(to_num(@stats["datacenter_bots"]))}</span>
              </div>
              <div class="flex justify-between text-sm">
                <span class="text-gray-600">VPN</span>
                <span class="font-medium">{format_number(to_num(@stats["vpn_bots"]))}</span>
              </div>
              <div class="flex justify-between text-sm">
                <span class="text-gray-600">Tor</span>
                <span class="font-medium">{format_number(to_num(@stats["tor_bots"]))}</span>
              </div>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
          <%!-- Top Bot Pages --%>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-6 py-4 border-b border-gray-100">
              <h3 class="font-semibold text-gray-900">Most Targeted Pages</h3>
              <p class="text-xs text-gray-500 mt-0.5">Pages bots hit most frequently</p>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Page
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Hits
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Bots
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@top_pages == []}>
                  <td colspan="3" class="px-6 py-8 text-center text-gray-500">
                    No bot pageviews detected.
                  </td>
                </tr>
                <tr :for={p <- @top_pages} class="hover:bg-gray-50">
                  <td class="px-6 py-3 text-sm text-indigo-600 font-mono truncate max-w-xs">
                    {p["url_path"]}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {p["hits"]}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-500 text-right tabular-nums">
                    {p["bots"]}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Top Bot User Agents --%>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-6 py-4 border-b border-gray-100">
              <h3 class="font-semibold text-gray-900">Top Bot User Agents</h3>
              <p class="text-xs text-gray-500 mt-0.5">Most common bot signatures</p>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    User Agent
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Hits
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@top_uas == []}>
                  <td colspan="2" class="px-6 py-8 text-center text-gray-500">
                    No bot user agents detected.
                  </td>
                </tr>
                <tr :for={ua <- @top_uas} class="hover:bg-gray-50">
                  <td
                    class="px-6 py-3 text-xs text-gray-700 font-mono truncate max-w-sm"
                    title={ua["user_agent"]}
                  >
                    {String.slice(ua["user_agent"] || "", 0, 80)}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {ua["hits"]}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
