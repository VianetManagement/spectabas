defmodule SpectabasWeb.Dashboard.GoalDetailLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Goals, Analytics, Visitors}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id, "goal_id" => goal_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      goal = Goals.get_goal_for_site!(site, goal_id)

      {:ok,
       socket
       |> assign(:page_title, "#{goal.name} - Goals - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:goal, goal)
       |> assign(:range, "30d")
       |> assign(:stats, nil)
       |> assign(:timeseries_json, "{}")
       |> assign(:top_sources, [])
       |> assign(:top_pages, [])
       |> assign(:devices, [])
       |> assign(:geo, [])
       |> assign(:recent_completers, [])
       |> assign(:email_map, %{})
       |> assign(:click_element_info, nil)
       |> assign(:loading, true)
       |> then(fn s ->
         send(self(), :load_data)
         s
       end)}
    end
  end

  @default_stats %{
    total_completions: 0,
    unique_completers: 0,
    conversion_rate: 0.0,
    avg_per_visitor: 0.0,
    total_visitors: 0
  }

  @impl true
  def handle_info(:load_data, socket) do
    site = socket.assigns.site
    user = socket.assigns.user
    goal = socket.assigns.goal
    range = socket.assigns.range

    # Run all 7 ClickHouse queries in parallel
    tasks = %{
      stats:
        Task.async(fn ->
          safe_query(
            fn -> Analytics.goal_detail_stats(site, user, goal, range) end,
            @default_stats
          )
        end),
      timeseries:
        Task.async(fn ->
          safe_query(fn -> Analytics.goal_completion_timeseries(site, user, goal, range) end)
        end),
      sources:
        Task.async(fn ->
          safe_query(fn -> Analytics.goal_source_attribution(site, user, goal, range) end)
        end),
      pages:
        Task.async(fn ->
          safe_query(fn -> Analytics.goal_top_pages(site, user, goal, range) end)
        end),
      devices:
        Task.async(fn ->
          safe_query(fn -> Analytics.goal_device_breakdown(site, user, goal, range) end)
        end),
      geo:
        Task.async(fn ->
          safe_query(fn -> Analytics.goal_geo_breakdown(site, user, goal, range) end)
        end),
      completers:
        Task.async(fn ->
          safe_query(fn -> Analytics.goal_recent_completers(site, user, goal, range) end)
        end)
    }

    results = Map.new(tasks, fn {key, task} -> {key, Task.await(task, 15_000)} end)

    stats = results.stats

    stats =
      if is_map(stats) and Map.has_key?(stats, :total_completions),
        do: stats,
        else: @default_stats

    timeseries = results.timeseries

    timeseries_json =
      try do
        Jason.encode!(%{
          labels: Enum.map(timeseries, & &1["day"]),
          visitors: Enum.map(timeseries, &to_num(&1["completions"])),
          pageviews: Enum.map(timeseries, &to_num(&1["unique_completers"])),
          metric: "visitors"
        })
      rescue
        _ -> "{}"
      end

    completers = results.completers
    visitor_ids = Enum.map(completers, & &1["visitor_id"]) |> Enum.reject(&is_nil/1)
    email_map = if visitor_ids != [], do: Visitors.emails_for_visitor_ids(visitor_ids), else: %{}

    click_info =
      if goal.goal_type == "click_element" do
        safe_query(fn -> Analytics.goal_click_element_details(site, user, goal) end)
        |> List.first()
      end

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:timeseries_json, timeseries_json)
     |> assign(:top_sources, Enum.take(results.sources, 10))
     |> assign(:top_pages, results.pages)
     |> assign(:devices, results.devices)
     |> assign(:geo, results.geo)
     |> assign(:recent_completers, completers)
     |> assign(:email_map, email_map)
     |> assign(:click_element_info, click_info)
     |> assign(:loading, false)}
  rescue
    _ -> {:noreply, assign(socket, :loading, false)}
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:loading, true)
     |> then(fn s ->
       send(self(), :load_data)
       s
     end)}
  end

  defp goal_type_label("pageview"), do: "Pageview"
  defp goal_type_label("custom_event"), do: "Custom Event"
  defp goal_type_label("click_element"), do: "Click Element"
  defp goal_type_label(t), do: t

  defp goal_type_classes("pageview"), do: "bg-blue-100 text-blue-800"
  defp goal_type_classes("custom_event"), do: "bg-purple-100 text-purple-800"
  defp goal_type_classes("click_element"), do: "bg-green-100 text-green-800"
  defp goal_type_classes(_), do: "bg-gray-100 text-gray-800"

  defp goal_target(goal) do
    goal.page_path || goal.event_name || goal.element_selector || "-"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title={@goal.name}
      page_description="Goal detail — completions, sources, pages, and visitor breakdown."
      active="goals"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <%!-- Header --%>
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/goals"}
            class="text-sm text-indigo-600 hover:text-indigo-800 mb-2 inline-block"
          >
            &larr; Back to Goals
          </.link>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-bold text-gray-900">{@goal.name}</h1>
              <span class={[
                "inline-flex items-center px-2.5 py-0.5 rounded-lg text-xs font-medium",
                goal_type_classes(@goal.goal_type)
              ]}>
                {goal_type_label(@goal.goal_type)}
              </span>
              <span class="text-sm text-gray-500 font-mono">{goal_target(@goal)}</span>
            </div>
            <div class="flex gap-1">
              <button
                :for={r <- ~w(7d 30d 90d)}
                phx-click="change_range"
                phx-value-range={r}
                class={[
                  "px-3 py-1.5 text-sm font-medium rounded-lg",
                  if(@range == r,
                    do: "bg-indigo-600 text-white",
                    else: "text-gray-600 hover:bg-gray-100"
                  )
                ]}
              >
                {r}
              </button>
            </div>
          </div>
        </div>

        <div :if={@loading} class="text-center py-16 text-gray-400">Loading...</div>

        <div :if={!@loading && @stats}>
          <%!-- Stat Cards --%>
          <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Total Completions</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">
                {format_number(@stats.total_completions)}
              </p>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Unique Visitors</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">
                {format_number(@stats.unique_completers)}
              </p>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Conversion Rate</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">{@stats.conversion_rate}%</p>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Avg per Visitor</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">{@stats.avg_per_visitor}</p>
            </div>
          </div>

          <%!-- Completion Trend Chart --%>
          <div class="bg-white rounded-lg shadow p-5 mb-8">
            <h2 class="text-sm font-semibold text-gray-700 mb-3">Completion Trend</h2>
            <div
              id={"goal-chart-#{@range}"}
              phx-hook="TimeseriesChart"
              phx-update="ignore"
              data-chart={@timeseries_json}
              class="h-48 sm:h-[240px] relative"
            >
              <canvas></canvas>
            </div>
          </div>

          <%!-- Click Element Info (if applicable) --%>
          <div :if={@click_element_info} class="bg-white rounded-lg shadow p-5 mb-8">
            <h2 class="text-sm font-semibold text-gray-700 mb-3">Element Details</h2>
            <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 text-sm">
              <div>
                <p class="text-gray-500">Tag</p>
                <p class="font-mono font-medium mt-1">{"<#{@click_element_info["element_tag"]}>"}</p>
              </div>
              <div>
                <p class="text-gray-500">Text</p>
                <p class="font-medium mt-1">{@click_element_info["element_text"]}</p>
              </div>
              <div :if={@click_element_info["element_id"] != ""}>
                <p class="text-gray-500">ID</p>
                <p class="font-mono font-medium mt-1">#{@click_element_info["element_id"]}</p>
              </div>
              <div :if={@click_element_info["element_classes"] != ""}>
                <p class="text-gray-500">Classes</p>
                <p class="font-mono text-xs mt-1 truncate">
                  {@click_element_info["element_classes"]}
                </p>
              </div>
            </div>
            <div
              :if={
                is_list(@click_element_info["pages_clicked"]) &&
                  @click_element_info["pages_clicked"] != []
              }
              class="mt-3 pt-3 border-t border-gray-100"
            >
              <p class="text-xs text-gray-500 mb-1">Pages where clicked:</p>
              <div class="flex flex-wrap gap-1">
                <span
                  :for={page <- @click_element_info["pages_clicked"]}
                  class="inline-flex px-2 py-0.5 rounded bg-gray-100 text-xs font-mono text-gray-600"
                >
                  {page}
                </span>
              </div>
            </div>
          </div>

          <%!-- Two-column: Sources + Pages --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-200">
                <h2 class="text-sm font-semibold text-gray-700">Top Sources</h2>
              </div>
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Source
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Completers
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :if={@top_sources == []}>
                    <td colspan="2" class="px-5 py-4 text-center text-sm text-gray-400">No data</td>
                  </tr>
                  <tr :for={src <- @top_sources} class="hover:bg-gray-50">
                    <td class="px-5 py-2 text-sm text-gray-900">{src["source"]}</td>
                    <td class="px-5 py-2 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(src["completers"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-200">
                <h2 class="text-sm font-semibold text-gray-700">Top Pages</h2>
              </div>
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Page
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Completions
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :if={@top_pages == []}>
                    <td colspan="3" class="px-5 py-4 text-center text-sm text-gray-400">No data</td>
                  </tr>
                  <tr :for={page <- @top_pages} class="hover:bg-gray-50">
                    <td class="px-5 py-2 text-sm text-gray-900 font-mono truncate max-w-[200px]">
                      {page["url_path"]}
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(page["completions"]))}
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(page["unique_completers"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Two-column: Devices + Geography --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-200">
                <h2 class="text-sm font-semibold text-gray-700">Devices</h2>
              </div>
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Device
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Completions
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :for={d <- @devices} class="hover:bg-gray-50">
                    <td class="px-5 py-2 text-sm text-gray-900">{d["device"]}</td>
                    <td class="px-5 py-2 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(d["completions"]))}
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(d["unique_completers"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-200">
                <h2 class="text-sm font-semibold text-gray-700">Top Countries</h2>
              </div>
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Country
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Completions
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :for={g <- @geo} class="hover:bg-gray-50">
                    <td class="px-5 py-2 text-sm text-gray-900">{g["country"]}</td>
                    <td class="px-5 py-2 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(g["completions"]))}
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(g["unique_completers"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Recent Completers --%>
          <div class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-200">
              <h2 class="text-sm font-semibold text-gray-700">Recent Completers</h2>
            </div>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Visitor
                    </th>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Email
                    </th>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Last Page
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Count
                    </th>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Device
                    </th>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Country
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :if={@recent_completers == []}>
                    <td colspan="6" class="px-5 py-4 text-center text-sm text-gray-400">
                      No completers found
                    </td>
                  </tr>
                  <tr :for={c <- @recent_completers} class="hover:bg-gray-50">
                    <td class="px-5 py-2 text-sm">
                      <.link
                        navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{c["visitor_id"]}"}
                        class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                      >
                        {String.slice(c["visitor_id"] || "", 0..11)}...
                      </.link>
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-600">
                      {Map.get(@email_map, c["visitor_id"], %{}) |> Map.get(:email, "—")}
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-600 font-mono truncate max-w-[180px]">
                      {c["last_url"]}
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-900 text-right tabular-nums font-semibold">
                      {format_number(to_num(c["completion_count"]))}
                    </td>
                    <td class="px-5 py-2 text-sm text-gray-600">{c["device"]}</td>
                    <td class="px-5 py-2 text-sm text-gray-600">{c["country"]}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
