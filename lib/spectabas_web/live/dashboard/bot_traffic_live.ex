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
      socket =
        socket
        |> assign(:page_title, "Bot Traffic - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:modal_ua, nil)
        |> assign(:modal_details, nil)
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  # Open the UA details modal. UA strings are looked up from the current
  # @top_uas assign via an index (they can contain any character and are too
  # long to round-trip through a phx-value attribute safely).
  def handle_event("open_ua", %{"idx" => idx_str}, socket) do
    case Integer.parse(idx_str) do
      {idx, _} ->
        ua =
          socket.assigns.top_uas
          |> Enum.at(idx, %{})
          |> Map.get("user_agent")

        if is_binary(ua) and ua != "" do
          details =
            case Analytics.bot_ua_details(
                   socket.assigns.site,
                   socket.assigns.user,
                   ua,
                   range_to_period(socket.assigns.date_range)
                 ) do
              {:ok, d} -> d
              _ -> %{summary: %{}, pages: [], ips: []}
            end

          {:noreply,
           socket
           |> assign(:modal_ua, ua)
           |> assign(:modal_details, details)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_ua", _params, socket) do
    {:noreply, socket |> assign(:modal_ua, nil) |> assign(:modal_details, nil)}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    stats = safe_query(fn -> Analytics.bot_stats(site, user, period) end, %{})
    top_pages = safe_query(fn -> Analytics.bot_top_pages(site, user, period) end)
    top_uas = safe_query(fn -> Analytics.bot_top_user_agents(site, user, period) end)
    daily_trend = safe_query(fn -> Analytics.bot_daily_trend(site, user, period) end)

    trend_chart_json = build_trend_chart_json(daily_trend)
    chart_key = "bot-#{range}-#{System.unique_integer([:positive])}"

    socket
    |> assign(:stats, stats)
    |> assign(:top_pages, top_pages)
    |> assign(:top_uas, top_uas)
    |> assign(:daily_trend, daily_trend)
    |> assign(:trend_chart_json, trend_chart_json)
    |> assign(:chart_key, chart_key)
  end

  defp build_trend_chart_json(daily_trend) do
    labels = Enum.map(daily_trend, fn r -> short_date(r["bucket"]) end)
    bot = Enum.map(daily_trend, fn r -> to_num(r["bot_events"]) end)
    human = Enum.map(daily_trend, fn r -> to_num(r["human_events"]) end)

    Jason.encode!(%{
      labels: labels,
      datasets: [
        %{label: "Human", data: human, type: "line", color: "#22c55e", fill: true},
        %{label: "Bot", data: bot, type: "line", color: "#ef4444", fill: true}
      ]
    })
  end

  defp short_date(nil), do: ""

  defp short_date(d) when is_binary(d) do
    case String.split(d, "-") do
      [_y, m, day] -> "#{m}/#{day}"
      _ -> d
    end
  end

  defp short_date(d), do: to_string(d)

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

        <%= if @loading do %>
          <div class="bg-white rounded-lg shadow p-12 text-center">
            <div class="inline-flex items-center gap-3 text-gray-600">
              <svg class="animate-spin h-5 w-5 text-indigo-600" viewBox="0 0 24 24" fill="none">
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
              <span class="text-sm">Loading...</span>
            </div>
          </div>
        <% else %>
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

          <%!-- Bot vs Human trend chart --%>
          <div class="bg-white rounded-lg shadow p-6 mb-8">
            <h3 class="text-sm font-semibold text-gray-700 mb-3">Bot vs Human Traffic</h3>
            <div
              id={"bot-trend-" <> @chart_key}
              phx-hook="SearchChart"
              data-chart={@trend_chart_json}
              class="h-48 relative"
            >
              <canvas></canvas>
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
                      {format_number(to_num(p["hits"]))}
                    </td>
                    <td class="px-6 py-3 text-sm text-gray-500 text-right tabular-nums">
                      {format_number(to_num(p["bots"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Top Bot User Agents --%>
            <div class="bg-white rounded-lg shadow overflow-x-auto">
              <div class="px-6 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Top Bot User Agents</h3>
                <p class="text-xs text-gray-500 mt-0.5">
                  Click a row to see full user agent and targeting details.
                </p>
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
                  <tr
                    :for={{ua, idx} <- Enum.with_index(@top_uas)}
                    class="hover:bg-indigo-50 cursor-pointer"
                    phx-click="open_ua"
                    phx-value-idx={idx}
                  >
                    <td
                      class="px-6 py-3 text-xs text-gray-700 font-mono truncate max-w-sm"
                      title={ua["user_agent"]}
                    >
                      {String.slice(ua["user_agent"] || "", 0, 80)}
                    </td>
                    <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(ua["hits"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- User Agent details modal --%>
      <%= if @modal_ua do %>
        <%!-- Backdrop: clicks outside the card close the modal. --%>
        <div
          class="fixed inset-0 bg-gray-900/50 z-40"
          phx-click="close_ua"
          aria-hidden="true"
        >
        </div>
        <%!-- Modal card: absolute-positioned above the backdrop. No
        pointer-events trickery — the card just sits on top. The × button
        has its own phx-click binding which fires directly on the element. --%>
        <div class="fixed left-1/2 -translate-x-1/2 top-10 bottom-10 z-50 w-[calc(100%-2rem)] max-w-3xl bg-white rounded-lg shadow-2xl overflow-y-auto flex flex-col">
          <div class="px-6 py-4 border-b border-gray-200 flex items-start justify-between sticky top-0 bg-white rounded-t-lg">
            <div>
              <h3 class="text-lg font-semibold text-gray-900">User Agent Details</h3>
              <p class="text-xs text-gray-500 mt-0.5">
                Bot traffic details for the selected signature in the {@date_range} window.
              </p>
            </div>
            <button
              type="button"
              phx-click="close_ua"
              class="shrink-0 ml-4 text-gray-400 hover:text-gray-700 text-2xl leading-none px-2"
              aria-label="Close"
            >
              &times;
            </button>
          </div>

          <div class="px-6 py-4 space-y-5">
            <%!-- Full UA string --%>
            <div>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-1">User Agent</h4>
              <div class="bg-gray-50 border border-gray-200 rounded p-3 text-xs font-mono text-gray-800 break-all">
                {@modal_ua}
              </div>
            </div>

            <%!-- Summary grid --%>
            <% s = @modal_details[:summary] || %{} %>
            <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
              <div>
                <div class="text-xs text-gray-500">Hits</div>
                <div class="text-lg font-semibold text-gray-900">
                  {format_number(to_num(s["hits"]))}
                </div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Unique Visitors</div>
                <div class="text-lg font-semibold text-gray-900">
                  {format_number(to_num(s["unique_visitors"]))}
                </div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Unique IPs</div>
                <div class="text-lg font-semibold text-gray-900">
                  {format_number(to_num(s["unique_ips"]))}
                </div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Browser</div>
                <div class="text-sm text-gray-800">
                  {blank_to_dash(s["browser"])}
                </div>
              </div>
              <div>
                <div class="text-xs text-gray-500">OS</div>
                <div class="text-sm text-gray-800">
                  {blank_to_dash(s["os"])}
                </div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Device Type</div>
                <div class="text-sm text-gray-800">
                  {blank_to_dash(s["device_type"])}
                </div>
              </div>
              <div class="col-span-2 sm:col-span-3">
                <div class="text-xs text-gray-500">Network</div>
                <div class="text-sm text-gray-800">
                  {blank_to_dash(s["asn_org"])}
                </div>
              </div>
              <div>
                <div class="text-xs text-gray-500">First Seen</div>
                <div class="text-sm text-gray-800">{blank_to_dash(s["first_seen"])}</div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Last Seen</div>
                <div class="text-sm text-gray-800">{blank_to_dash(s["last_seen"])}</div>
              </div>
            </div>

            <%!-- Top pages --%>
            <div>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">
                Top Pages Targeted
              </h4>
              <%= if @modal_details[:pages] == [] do %>
                <p class="text-sm text-gray-500 italic">No pageviews recorded for this UA.</p>
              <% else %>
                <table class="w-full text-sm">
                  <thead>
                    <tr class="text-gray-600 border-b border-gray-200">
                      <th class="text-left py-1 font-medium">Page</th>
                      <th class="text-right py-1 font-medium">Hits</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for p <- @modal_details[:pages] do %>
                      <tr class="border-b border-gray-50">
                        <td class="py-1.5 text-indigo-700 font-mono truncate max-w-md">
                          {p["url_path"]}
                        </td>
                        <td class="text-right py-1.5 text-gray-700 tabular-nums">
                          {format_number(to_num(p["hits"]))}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>

            <%!-- Top IPs --%>
            <div>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">Top IPs</h4>
              <%= if @modal_details[:ips] == [] do %>
                <p class="text-sm text-gray-500 italic">No IP data.</p>
              <% else %>
                <table class="w-full text-sm">
                  <thead>
                    <tr class="text-gray-600 border-b border-gray-200">
                      <th class="text-left py-1 font-medium">IP</th>
                      <th class="text-left py-1 font-medium">Country</th>
                      <th class="text-left py-1 font-medium hidden sm:table-cell">Network</th>
                      <th class="text-right py-1 font-medium">Hits</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for ip <- @modal_details[:ips] do %>
                      <tr class="border-b border-gray-50">
                        <td class="py-1.5 font-mono text-xs">
                          <.link
                            navigate={~p"/dashboard/sites/#{@site.id}/ip/#{ip["ip_address"]}"}
                            class="text-indigo-600 hover:text-indigo-800"
                          >
                            {ip["ip_address"]}
                          </.link>
                        </td>
                        <td class="py-1.5 text-gray-700">{blank_to_dash(ip["country"])}</td>
                        <td class="py-1.5 text-gray-600 truncate max-w-xs hidden sm:table-cell">
                          {blank_to_dash(ip["asn_org"])}
                        </td>
                        <td class="text-right py-1.5 text-gray-700 tabular-nums">
                          {format_number(to_num(ip["hits"]))}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </.dashboard_layout>
    """
  end
end
