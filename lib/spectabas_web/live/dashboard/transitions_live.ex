defmodule SpectabasWeb.Dashboard.TransitionsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Page detail — single-page analytics: traffic, sources, engagement, clicks, goals."

  alias Spectabas.{Accounts, Sites, Analytics}
  alias Spectabas.Analytics.ChannelClassifier
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      page = params["page"] || "/"

      socket =
        socket
        |> assign(:page_title, "Page detail - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:current_page, page)
        |> assign_loading_defaults()
        |> assign(:chart_metric, "visitors")
        |> assign(:chart_key, 0)
        |> assign(:cache_key, 0)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    %{site: site, user: user, date_range: range, current_page: page, cache_key: cache_key} =
      socket.assigns

    period = range_to_period(range)
    days = range_to_days(range)
    lv_pid = self()

    # Render the shell immediately. All queries run in parallel as Tasks
    # so 30d / 90d switches feel instant — sections fill in as they arrive.

    spawn_deferred(lv_pid, :transitions, cache_key, %{previous: [], next: [], totals: %{}}, fn ->
      Analytics.page_transitions(site, user, page, period)
    end)

    spawn_chart(lv_pid, site, user, page, range, cache_key)

    spawn_deferred(lv_pid, :page_perf, cache_key, %{}, fn ->
      Analytics.rum_vitals_by_page(site, user, period, page)
    end)

    spawn_deferred(lv_pid, :engagement, cache_key, %{}, fn ->
      Analytics.page_engagement(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :referrers, cache_key, [], fn ->
      Analytics.page_referrers(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :countries, cache_key, [], fn ->
      Analytics.page_countries(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :devices, cache_key, [], fn ->
      Analytics.page_devices(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :clicks, cache_key, [], fn ->
      Analytics.page_clicks(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :outbound, cache_key, [], fn ->
      Analytics.page_outbound(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :goals, cache_key, [], fn ->
      Analytics.page_goals(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :keywords, cache_key, [], fn ->
      Analytics.page_search_keywords(site, user, page, days)
    end)

    spawn_deferred(lv_pid, :heatmap, cache_key, [], fn ->
      Analytics.page_hour_heatmap(site, user, page, period)
    end)

    spawn_deferred(lv_pid, :visitor_split, cache_key, [], fn ->
      Analytics.page_visitor_split(site, user, page, period)
    end)

    {:noreply, socket}
  end

  def handle_info({:deferred_result, :transitions, value, cache_key}, socket) do
    if cache_key == socket.assigns.cache_key do
      transitions = value || %{previous: [], next: [], totals: %{}}

      {:noreply,
       socket
       |> assign(:transitions, %{previous: transitions.previous, next: transitions.next})
       |> assign(:totals, transitions.totals || %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:deferred_result, :chart, chart_data, cache_key}, socket) do
    if cache_key == socket.assigns.cache_key do
      {:noreply,
       socket
       |> assign(:chart_data, chart_data)
       |> assign(:chart_json, encode_chart(chart_data, socket.assigns.chart_metric))
       |> assign(:chart_key, socket.assigns.chart_key + 1)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:deferred_result, key, value, cache_key}, socket) do
    if cache_key == socket.assigns.cache_key do
      {:noreply, assign(socket, key, value)}
    else
      {:noreply, socket}
    end
  end

  defp spawn_deferred(lv_pid, key, cache_key, fallback, fun) do
    Task.start(fn ->
      result = safe_query(fun, fallback)
      send(lv_pid, {:deferred_result, key, result, cache_key})
    end)
  end

  defp spawn_chart(lv_pid, site, user, page, range, cache_key) do
    Task.start(fn ->
      chart_data = build_chart_data(site, user, page, range)
      send(lv_pid, {:deferred_result, :chart, chart_data, cache_key})
    end)
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    socket =
      socket
      |> assign(:date_range, range)
      |> assign(:cache_key, socket.assigns.cache_key + 1)
      |> reset_deferred()

    send(self(), :load_data)
    {:noreply, socket}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    page = if page == "", do: "/", else: page

    socket =
      socket
      |> assign(:current_page, page)
      |> assign(:cache_key, socket.assigns.cache_key + 1)
      |> reset_deferred()

    send(self(), :load_data)
    {:noreply, socket}
  end

  def handle_event("navigate_page", %{"path" => path}, socket) do
    socket =
      socket
      |> assign(:current_page, path)
      |> assign(:cache_key, socket.assigns.cache_key + 1)
      |> reset_deferred()

    send(self(), :load_data)
    {:noreply, socket}
  end

  def handle_event("toggle_metric", %{"metric" => metric}, socket) do
    {:noreply,
     socket
     |> assign(:chart_metric, metric)
     |> assign(:chart_json, encode_chart(socket.assigns.chart_data, metric))
     |> assign(:chart_key, socket.assigns.chart_key + 1)}
  end

  defp reset_deferred(socket), do: assign_loading_defaults(socket)

  defp assign_loading_defaults(socket) do
    socket
    |> assign(:transitions, nil)
    |> assign(:totals, nil)
    |> assign(:chart_data, nil)
    |> assign(:chart_json, "{}")
    |> assign(:page_perf, nil)
    |> assign(:engagement, nil)
    |> assign(:referrers, nil)
    |> assign(:countries, nil)
    |> assign(:devices, nil)
    |> assign(:clicks, nil)
    |> assign(:outbound, nil)
    |> assign(:goals, nil)
    |> assign(:keywords, nil)
    |> assign(:heatmap, nil)
    |> assign(:visitor_split, nil)
  end

  defp build_chart_data(site, user, page, range) do
    period = range_to_period(range)
    %{from: from, to: to} = ensure_range(period)
    span_seconds = DateTime.diff(to, from, :second)
    prev_to = DateTime.add(from, -1, :second)
    prev_from = DateTime.add(prev_to, -span_seconds, :second)

    timeseries_fn =
      if range == "24h",
        do: &Analytics.page_timeseries/4,
        else: &Analytics.page_timeseries_fast/4

    current_rows =
      safe_query(fn -> timeseries_fn.(site, user, page, %{from: from, to: to}) end, [])

    previous_rows =
      safe_query(
        fn -> timeseries_fn.(site, user, page, %{from: prev_from, to: prev_to}) end,
        []
      )

    %{current: current_rows, previous: previous_rows, range: range}
  end

  defp encode_chart(%{current: current, previous: previous, range: range}, metric) do
    labels = Enum.map(current, & &1["bucket"]) |> Enum.map(&format_bucket(&1, range))
    pageviews = Enum.map(current, &to_num(&1["pageviews"]))
    visitors = Enum.map(current, &to_num(&1["visitors"]))

    prev_pageviews = pad_to_length(Enum.map(previous, &to_num(&1["pageviews"])), length(current))
    prev_visitors = pad_to_length(Enum.map(previous, &to_num(&1["visitors"])), length(current))

    Jason.encode!(%{
      labels: labels,
      pageviews: pageviews,
      visitors: visitors,
      previous_pageviews: prev_pageviews,
      previous_visitors: prev_visitors,
      metric: metric
    })
  rescue
    _ -> "{}"
  end

  defp pad_to_length(list, target_len) do
    cur = length(list)

    cond do
      cur == target_len -> list
      cur > target_len -> Enum.take(list, target_len)
      true -> list ++ List.duplicate(0, target_len - cur)
    end
  end

  defp ensure_range(period) when is_atom(period) do
    Analytics.period_to_date_range(period, "UTC")
  end

  defp format_bucket(nil, _), do: ""

  defp format_bucket(bucket, "24h") do
    case bucket do
      <<_y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2), " ",
        h::binary-size(2), _rest::binary>> ->
        "#{m}/#{d} #{h}:00"

      <<_::binary-size(10), "T", h::binary-size(2), _rest::binary>> ->
        "#{h}:00"

      _ ->
        to_string(bucket)
    end
  end

  defp format_bucket(bucket, _) do
    case bucket do
      <<_y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2), _rest::binary>> ->
        "#{m}/#{d}"

      _ ->
        to_string(bucket)
    end
  end

  defp range_to_days("24h"), do: 1
  defp range_to_days("7d"), do: 7
  defp range_to_days("30d"), do: 30
  defp range_to_days("90d"), do: 90
  defp range_to_days(_), do: 7

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Page detail"
      page_description="Per-page analytics: traffic, sources, engagement, clicks, conversions."
      active="transitions"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Page detail</h1>
            <p class="text-sm text-gray-500 mt-1">
              Drill into a single page. Compare to the prior period.
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"24h", "24h"}, {"7d", "7 days"}, {"30d", "30 days"}, {"90d", "90 days"}]}
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

        <%!-- Page selector --%>
        <div class="bg-white rounded-lg shadow p-5 mb-6">
          <form phx-submit="change_page" class="flex items-end gap-3">
            <div class="flex-1">
              <label class="block text-xs font-medium text-gray-500 mb-1">Page path</label>
              <input
                type="text"
                name="page"
                value={@current_page}
                class="block w-full rounded-lg border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500 font-mono"
                placeholder="/pricing"
              />
            </div>
            <button
              type="submit"
              class="px-4 py-2 text-sm font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700"
            >
              Analyze
            </button>
          </form>
        </div>

        <div class="space-y-6">
          <%!-- Current page header strip --%>
          <div class="bg-indigo-50 rounded-lg p-5 text-center">
            <p class="text-xs text-indigo-600 font-medium uppercase tracking-wide">Page</p>
            <p class="text-2xl font-bold text-indigo-900 font-mono mt-1 break-all">{@current_page}</p>
            <div
              :if={is_nil(@totals)}
              class="flex justify-center mt-3 text-indigo-500"
            >
              <.death_star_spinner class="w-5 h-5" />
            </div>
            <div
              :if={!is_nil(@totals)}
              class="flex flex-wrap justify-center gap-x-8 gap-y-2 mt-3 text-sm text-indigo-700"
            >
              <span><strong>{format_number(to_num(@totals["total_views"]))}</strong> views</span>
              <span>
                <strong>{format_number(to_num(@totals["unique_visitors"]))}</strong> visitors
              </span>
              <span><strong>{format_number(to_num(@totals["sessions"]))}</strong> sessions</span>
            </div>
            <div
              :if={!is_nil(@page_perf) and to_num(@page_perf["samples"]) > 0}
              class="flex justify-center gap-6 mt-3 pt-3 border-t border-indigo-200"
            >
              <.perf_stat label="Load" value={to_num(@page_perf["page_load"])} />
              <.perf_stat label="LCP" value={to_num(@page_perf["lcp"])} />
              <.perf_stat label="FCP" value={to_num(@page_perf["fcp"])} />
              <span class="text-xs text-indigo-400 self-end">
                {to_num(@page_perf["samples"])} RUM samples
              </span>
            </div>
          </div>

          <%!-- Engagement strip --%>
          <div :if={is_nil(@engagement)} class="grid grid-cols-2 md:grid-cols-4 gap-3">
            <.metric_card_loading label="Bounce rate" />
            <.metric_card_loading label="Avg time on page" />
            <.metric_card_loading label="Entry rate" />
            <.metric_card_loading label="Exit rate" />
          </div>
          <div :if={!is_nil(@engagement)} class="grid grid-cols-2 md:grid-cols-4 gap-3">
            <.metric_card
              label="Bounce rate"
              value={engagement_bounce_rate(@engagement)}
              suffix="%"
              hint="Sessions where this was the only page"
            />
            <.metric_card
              label="Avg time on page"
              value={format_seconds(to_num(@engagement["avg_duration"]))}
              hint="Average duration on this page"
            />
            <.metric_card
              label="Entry rate"
              value={percent(@engagement["entries"], @engagement["total_sessions"])}
              suffix="%"
              hint="% of sessions that started here"
            />
            <.metric_card
              label="Exit rate"
              value={percent(@engagement["exits"], @engagement["total_sessions"])}
              suffix="%"
              hint="% of sessions that ended here"
            />
          </div>

          <%!-- Traffic chart --%>
          <div class="bg-white rounded-lg shadow p-5">
            <div class="flex items-center justify-between mb-3">
              <div>
                <h3 class="font-semibold text-gray-900">Traffic over time</h3>
                <p class="text-xs text-gray-500">Dashed line = previous period</p>
              </div>
              <div class="flex gap-1 bg-gray-100 rounded-lg p-1">
                <button
                  :for={m <- ["visitors", "pageviews"]}
                  phx-click="toggle_metric"
                  phx-value-metric={m}
                  class={[
                    "px-3 py-1 text-xs font-medium rounded-md capitalize",
                    if(@chart_metric == m,
                      do: "bg-white shadow text-gray-900",
                      else: "text-gray-600 hover:text-gray-900"
                    )
                  ]}
                >
                  {m}
                </button>
              </div>
            </div>
            <div
              :if={is_nil(@chart_data)}
              class="h-64 flex items-center justify-center text-gray-400"
            >
              <.death_star_spinner class="w-8 h-8" />
            </div>
            <div
              :if={!is_nil(@chart_data)}
              id={"traffic-chart-#{@chart_key}"}
              phx-hook="TimeseriesChart"
              phx-update="ignore"
              data-chart={@chart_json}
              class="h-64"
            >
              <canvas></canvas>
            </div>
          </div>

          <%!-- Transition flow --%>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Came from</h3>
                <p class="text-xs text-gray-500">Pages visitors viewed before this one</p>
              </div>
              <.panel_spinner :if={is_nil(@transitions)} />
              <div :if={!is_nil(@transitions)} class="divide-y divide-gray-50">
                <div
                  :if={@transitions.previous == []}
                  class="px-5 py-8 text-center text-sm text-gray-500"
                >
                  No previous pages (entry point)
                </div>
                <button
                  :for={row <- @transitions.previous}
                  type="button"
                  class="w-full text-left px-5 py-3 flex items-center justify-between hover:bg-gray-50"
                  phx-click="navigate_page"
                  phx-value-path={row["prev_page"]}
                >
                  <span class="text-sm text-indigo-600 font-mono truncate mr-4">
                    {row["prev_page"]}
                  </span>
                  <span class="text-sm font-medium text-gray-600 tabular-nums">
                    {format_number(to_num(row["transitions"]))}
                  </span>
                </button>
              </div>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Went to</h3>
                <p class="text-xs text-gray-500">Pages visitors viewed after this one</p>
              </div>
              <.panel_spinner :if={is_nil(@transitions)} />
              <div :if={!is_nil(@transitions)} class="divide-y divide-gray-50">
                <div :if={@transitions.next == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No next pages (exit point)
                </div>
                <button
                  :for={row <- @transitions.next}
                  type="button"
                  class="w-full text-left px-5 py-3 flex items-center justify-between hover:bg-gray-50"
                  phx-click="navigate_page"
                  phx-value-path={row["next_page"]}
                >
                  <span class="text-sm text-indigo-600 font-mono truncate mr-4">
                    {row["next_page"]}
                  </span>
                  <span class="text-sm font-medium text-gray-600 tabular-nums">
                    {format_number(to_num(row["transitions"]))}
                  </span>
                </button>
              </div>
            </div>
          </div>

          <%!-- Acquisition: referrers + keywords --%>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Top referrers landing here</h3>
                <p class="text-xs text-gray-500">
                  External sources that started a session on this page
                </p>
              </div>
              <.panel_spinner :if={is_nil(@referrers)} />
              <div :if={!is_nil(@referrers)} class="divide-y divide-gray-50">
                <div :if={@referrers == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No external referrers
                </div>
                <div
                  :for={row <- @referrers || []}
                  class="px-5 py-3 flex items-center justify-between"
                >
                  <div class="min-w-0 mr-4">
                    <div class="text-sm text-gray-900 truncate">{row["referrer_domain"]}</div>
                    <div class="text-xs text-gray-500">
                      {ChannelClassifier.classify(
                        row["referrer_domain"],
                        row["utm_source"] || "",
                        row["utm_medium"] || ""
                      )}
                    </div>
                  </div>
                  <div class="text-sm font-medium text-gray-700 tabular-nums">
                    {format_number(to_num(row["sessions"]))} sess
                  </div>
                </div>
              </div>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Top search keywords</h3>
                <p class="text-xs text-gray-500">
                  Search Console + Bing — last {range_to_days(@date_range)}d
                </p>
              </div>
              <.panel_spinner :if={is_nil(@keywords)} />
              <div :if={!is_nil(@keywords)} class="divide-y divide-gray-50">
                <div :if={@keywords == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No search data for this page
                </div>
                <div
                  :for={row <- @keywords || []}
                  class="px-5 py-3 flex items-center justify-between"
                >
                  <div class="min-w-0 mr-4">
                    <div class="text-sm text-gray-900 truncate">{row["query"]}</div>
                    <div class="text-xs text-gray-500">
                      pos {row["avg_pos"]} · {row["source"]}
                    </div>
                  </div>
                  <div class="text-right">
                    <div class="text-sm font-medium text-gray-900 tabular-nums">
                      {format_number(to_num(row["total_clicks"]))} clicks
                    </div>
                    <div class="text-xs text-gray-500 tabular-nums">
                      {format_number(to_num(row["total_impressions"]))} imp
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Audience: countries + devices + new/returning --%>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Top countries</h3>
              </div>
              <.panel_spinner :if={is_nil(@countries)} />
              <div :if={!is_nil(@countries)} class="divide-y divide-gray-50">
                <div :if={@countries == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No data
                </div>
                <div
                  :for={row <- Enum.take(@countries || [], 10)}
                  class="px-5 py-2 flex items-center justify-between"
                >
                  <span class="text-sm text-gray-900 truncate mr-4">
                    {row["ip_country_name"] || row["ip_country"]}
                  </span>
                  <span class="text-sm text-gray-600 tabular-nums">
                    {format_number(to_num(row["unique_visitors"]))}
                  </span>
                </div>
              </div>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Devices</h3>
              </div>
              <.panel_spinner :if={is_nil(@devices)} />
              <div :if={!is_nil(@devices)} class="divide-y divide-gray-50">
                <div :if={@devices == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No data
                </div>
                <.device_row
                  :for={row <- @devices || []}
                  row={row}
                  total={device_total(@devices || [])}
                />
              </div>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">New vs returning</h3>
                <p class="text-xs text-gray-500">First-touch on this page</p>
              </div>
              <.panel_spinner :if={is_nil(@visitor_split)} />
              <div :if={!is_nil(@visitor_split)} class="divide-y divide-gray-50">
                <div :if={@visitor_split == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No data
                </div>
                <.split_row
                  :for={row <- @visitor_split || []}
                  row={row}
                  total={split_total(@visitor_split || [])}
                />
              </div>
            </div>
          </div>

          <%!-- Conversions: clicks, outbound, goals --%>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Top clicked elements</h3>
                <p class="text-xs text-gray-500">Auto-tracked clicks on this page</p>
              </div>
              <.panel_spinner :if={is_nil(@clicks)} />
              <div :if={!is_nil(@clicks)} class="divide-y divide-gray-50">
                <div :if={@clicks == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No clicks tracked
                </div>
                <div
                  :for={row <- Enum.take(@clicks || [], 10)}
                  class="px-5 py-2 flex items-center justify-between"
                >
                  <div class="min-w-0 mr-4">
                    <div class="text-sm text-gray-900 truncate">
                      {click_label(row)}
                    </div>
                    <div class="text-xs text-gray-500 truncate">
                      &lt;{row["element_tag"]}&gt;
                    </div>
                  </div>
                  <span class="text-sm text-gray-600 tabular-nums">
                    {format_number(to_num(row["clicks"]))}
                  </span>
                </div>
              </div>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Top outbound links</h3>
              </div>
              <.panel_spinner :if={is_nil(@outbound)} />
              <div :if={!is_nil(@outbound)} class="divide-y divide-gray-50">
                <div :if={@outbound == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No outbound links
                </div>
                <div
                  :for={row <- Enum.take(@outbound || [], 10)}
                  class="px-5 py-2 flex items-center justify-between"
                >
                  <div class="min-w-0 mr-4">
                    <div class="text-sm text-gray-900 truncate">{row["domain"]}</div>
                    <div class="text-xs text-gray-500 truncate font-mono">{row["url"]}</div>
                  </div>
                  <span class="text-sm text-gray-600 tabular-nums">
                    {format_number(to_num(row["hits"]))}
                  </span>
                </div>
              </div>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-4 border-b border-gray-100">
                <h3 class="font-semibold text-gray-900">Goals from page viewers</h3>
                <p class="text-xs text-gray-500">Goal completions by visitors who saw this page</p>
              </div>
              <.panel_spinner :if={is_nil(@goals)} />
              <div :if={!is_nil(@goals)} class="divide-y divide-gray-50">
                <div :if={@goals == []} class="px-5 py-8 text-center text-sm text-gray-500">
                  No goals completed
                </div>
                <div
                  :for={goal <- @goals || []}
                  class="px-5 py-2 flex items-center justify-between"
                >
                  <div class="min-w-0 mr-4">
                    <div class="text-sm text-gray-900 truncate">{goal.name}</div>
                    <div class="text-xs text-gray-500 capitalize">{goal.goal_type}</div>
                  </div>
                  <div class="text-right">
                    <div class="text-sm font-medium text-gray-900 tabular-nums">
                      {format_number(goal.completions)}
                    </div>
                    <div class="text-xs text-gray-500 tabular-nums">
                      {format_number(goal.unique_completers)} visitors
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Hour of day x day of week heatmap --%>
          <div class="bg-white rounded-lg shadow p-5">
            <div class="flex items-center justify-between mb-3">
              <div>
                <h3 class="font-semibold text-gray-900">When visitors view this page</h3>
                <p class="text-xs text-gray-500">
                  Hour of day (rows) × day of week (columns), site timezone
                </p>
              </div>
            </div>
            <div :if={is_nil(@heatmap)} class="flex items-center justify-center py-8 text-gray-400">
              <.death_star_spinner class="w-6 h-6" />
            </div>
            <div
              :if={!is_nil(@heatmap) and @heatmap == []}
              class="text-center py-8 text-sm text-gray-500"
            >
              No data
            </div>
            <.heatmap_grid :if={!is_nil(@heatmap) and @heatmap != []} cells={@heatmap} />
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  # ---- Components ----

  defp panel_spinner(assigns) do
    ~H"""
    <div class="flex items-center justify-center py-12 text-gray-400">
      <.death_star_spinner class="w-6 h-6" />
    </div>
    """
  end

  defp metric_card_loading(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <div class="text-xs font-medium text-gray-500 uppercase tracking-wide">{@label}</div>
      <div class="mt-2 text-gray-300">
        <.death_star_spinner class="w-5 h-5" />
      </div>
    </div>
    """
  end

  defp metric_card(assigns) do
    assigns = assign_new(assigns, :suffix, fn -> "" end)
    assigns = assign_new(assigns, :hint, fn -> "" end)

    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <div class="text-xs font-medium text-gray-500 uppercase tracking-wide">{@label}</div>
      <div class="text-2xl font-bold text-gray-900 mt-1 tabular-nums">
        {@value}<span :if={@suffix != ""} class="text-base text-gray-500">{@suffix}</span>
      </div>
      <div :if={@hint != ""} class="text-xs text-gray-400 mt-1">{@hint}</div>
    </div>
    """
  end

  defp perf_stat(assigns) do
    ~H"""
    <div :if={@value > 0} class="text-center">
      <div class={"text-lg font-bold #{speed_color(@value)}"}>
        {format_ms(@value)}
      </div>
      <div class="text-xs text-indigo-500">{@label}</div>
    </div>
    """
  end

  defp device_row(assigns) do
    pct =
      if assigns.total > 0,
        do: round(to_num(assigns.row["unique_visitors"]) / assigns.total * 100),
        else: 0

    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="px-5 py-2">
      <div class="flex items-center justify-between text-sm mb-1">
        <span class="text-gray-900 capitalize truncate mr-4">{@row["device_type"]}</span>
        <span class="text-gray-600 tabular-nums">{@pct}%</span>
      </div>
      <div class="h-1.5 bg-gray-100 rounded-full overflow-hidden">
        <div class="h-full bg-indigo-500 rounded-full" style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end

  defp split_row(assigns) do
    pct =
      if assigns.total > 0,
        do: round(to_num(assigns.row["visitors"]) / assigns.total * 100),
        else: 0

    color = if assigns.row["visitor_type"] == "New", do: "bg-emerald-500", else: "bg-indigo-500"
    assigns = assign(assigns, pct: pct, color: color)

    ~H"""
    <div class="px-5 py-2">
      <div class="flex items-center justify-between text-sm mb-1">
        <span class="text-gray-900">{@row["visitor_type"]}</span>
        <span class="text-gray-600 tabular-nums">
          {format_number(to_num(@row["visitors"]))} ({@pct}%)
        </span>
      </div>
      <div class="h-1.5 bg-gray-100 rounded-full overflow-hidden">
        <div class={"h-full rounded-full #{@color}"} style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end

  defp heatmap_grid(assigns) do
    grid = build_heatmap_grid(assigns.cells)
    max_val = max_heatmap_value(grid)
    assigns = assign(assigns, grid: grid, max_val: max_val)

    ~H"""
    <div class="overflow-x-auto">
      <table class="text-xs">
        <thead>
          <tr>
            <th class="w-8"></th>
            <th
              :for={dow <- 1..7}
              class="px-1 text-center text-gray-500 font-normal w-10"
            >
              {dow_label(dow)}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={hour <- 0..23}>
            <td class="pr-2 text-right text-gray-400 tabular-nums">{format_hour(hour)}</td>
            <td :for={dow <- 1..7} class="p-0.5">
              <div
                class="w-9 h-5 rounded text-center"
                style={"background-color: #{heatmap_color(cell_val(@grid, hour, dow), @max_val)}"}
                title={"#{cell_val(@grid, hour, dow)} pageviews"}
              />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ---- Helpers ----

  defp engagement_bounce_rate(eng) do
    bounces = to_num(eng["bounces"])
    entries = to_num(eng["entries"])
    if entries > 0, do: round(bounces / entries * 100), else: 0
  end

  defp percent(num, denom) do
    n = to_num(num)
    d = to_num(denom)
    if d > 0, do: round(n / d * 100), else: 0
  end

  defp format_seconds(0), do: "0s"
  defp format_seconds(s) when is_integer(s) and s < 60, do: "#{s}s"

  defp format_seconds(s) when is_integer(s) do
    "#{div(s, 60)}m #{rem(s, 60)}s"
  end

  defp format_seconds(_), do: "0s"

  defp click_label(row) do
    text = String.trim(row["element_text"] || "")

    cond do
      text != "" -> text
      (row["element_id"] || "") != "" -> "##{row["element_id"]}"
      (row["element_href"] || "") != "" -> row["element_href"]
      true -> "(unlabeled)"
    end
  end

  defp device_total(devices) do
    Enum.reduce(devices, 0, &(to_num(&1["unique_visitors"]) + &2))
  end

  defp split_total(rows) do
    Enum.reduce(rows, 0, &(to_num(&1["visitors"]) + &2))
  end

  defp speed_color(ms) do
    cond do
      ms <= 1000 -> "text-green-700"
      ms <= 3000 -> "text-amber-700"
      true -> "text-red-700"
    end
  end

  defp build_heatmap_grid(rows) do
    Map.new(rows, fn r ->
      {{to_num(r["hour_of_day"]), to_num(r["day_of_week"])}, to_num(r["pageviews"])}
    end)
  end

  defp cell_val(grid, hour, dow), do: Map.get(grid, {hour, dow}, 0)

  defp max_heatmap_value(grid) do
    case Map.values(grid) do
      [] -> 0
      vals -> Enum.max(vals)
    end
  end

  defp heatmap_color(0, _), do: "#f9fafb"
  defp heatmap_color(_, 0), do: "#f9fafb"

  defp heatmap_color(val, max_val) do
    intensity = min(1.0, val / max_val)
    alpha = 0.1 + intensity * 0.9
    "rgba(99, 102, 241, #{Float.round(alpha, 2)})"
  end

  defp dow_label(1), do: "Mon"
  defp dow_label(2), do: "Tue"
  defp dow_label(3), do: "Wed"
  defp dow_label(4), do: "Thu"
  defp dow_label(5), do: "Fri"
  defp dow_label(6), do: "Sat"
  defp dow_label(7), do: "Sun"
  defp dow_label(_), do: ""

  defp format_hour(h) when h < 10, do: "0#{h}"
  defp format_hour(h), do: "#{h}"
end
