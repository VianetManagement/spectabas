defmodule SpectabasWeb.Dashboard.SearchKeywordsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, ClickHouse}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers, except: [format_number: 1]

  @allowed_sort_cols ~w(total_clicks total_impressions ctr avg_pos)
  @allowed_sort_dirs ~w(asc desc)

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Search Keywords - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "30d")
       |> assign(:source_filter, "all")
       |> assign(:sort_by, "total_clicks")
       |> assign(:sort_dir, "desc")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  def handle_event("change_source", %{"source" => source}, socket) do
    {:noreply, socket |> assign(:source_filter, source) |> load_data()}
  end

  def handle_event("sort", %{"col" => col}, socket) when col in @allowed_sort_cols do
    new_dir =
      if col == socket.assigns.sort_by do
        if socket.assigns.sort_dir == "desc", do: "asc", else: "desc"
      else
        "desc"
      end

    # Belt-and-suspenders: validate sort_dir even though it's toggled in code
    safe_dir = if new_dir in @allowed_sort_dirs, do: new_dir, else: "desc"

    {:noreply, socket |> assign(:sort_by, col) |> assign(:sort_dir, safe_dir) |> load_data()}
  end

  def handle_event("sort", _params, socket) do
    {:noreply, socket}
  end

  defp load_data(socket) do
    site = socket.assigns.site
    site_p = ClickHouse.param(site.id)
    range = socket.assigns.date_range
    source = socket.assigns.source_filter
    sort_by = socket.assigns.sort_by
    sort_dir = socket.assigns.sort_dir

    days =
      case range do
        "7d" -> 7
        "30d" -> 30
        "90d" -> 90
        _ -> 30
      end

    source_filter =
      case source do
        "google" -> "AND source = 'google'"
        "bing" -> "AND source = 'bing'"
        _ -> ""
      end

    order = "#{sort_by} #{sort_dir}"

    # Overview stats
    stats_sql = """
    SELECT
      sum(clicks) AS total_clicks,
      sum(impressions) AS total_impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS avg_ctr,
      round(avg(position), 1) AS avg_position,
      uniqExact(query) AS unique_queries
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      #{source_filter}
    """

    stats =
      case ClickHouse.query(stats_sql) do
        {:ok, [row | _]} -> row
        _ -> %{}
      end

    # Top queries
    queries_sql = """
    SELECT
      query,
      sum(clicks) AS total_clicks,
      sum(impressions) AS total_impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_pos
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      AND query != ''
      #{source_filter}
    GROUP BY query
    ORDER BY #{order}
    LIMIT 100
    """

    {queries, query_error} =
      case ClickHouse.query(queries_sql) do
        {:ok, rows} -> {rows, nil}
        {:error, e} -> {[], inspect(e) |> String.slice(0, 200)}
      end

    # Top pages
    pages_sql = """
    SELECT
      page,
      sum(clicks) AS total_clicks,
      sum(impressions) AS total_impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_pos
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      #{source_filter}
    GROUP BY page
    ORDER BY #{order}
    LIMIT 50
    """

    pages =
      case ClickHouse.query(pages_sql) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Ranking changes: queries with significant position changes (7d vs prior 7d)
    ranking_changes =
      case ClickHouse.query("""
           SELECT
             cur.query,
             cur.clicks AS current_clicks,
             cur.pos AS current_pos,
             prev.pos AS previous_pos,
             round(prev.pos - cur.pos, 1) AS pos_change
           FROM (
             SELECT query, sum(clicks) AS clicks, round(avg(position), 1) AS pos
             FROM search_console FINAL
             WHERE site_id = #{site_p} AND date >= today() - 7 #{source_filter}
             GROUP BY query HAVING sum(impressions) >= 5
           ) cur
           LEFT JOIN (
             SELECT query, round(avg(position), 1) AS pos
             FROM search_console FINAL
             WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7 #{source_filter}
             GROUP BY query HAVING sum(impressions) >= 5
           ) prev ON cur.query = prev.query
           WHERE prev.pos > 0 AND abs(cur.pos - prev.pos) >= 2
           ORDER BY pos_change DESC
           LIMIT 20
           """) do
        {:ok, rows} -> rows
        _ -> []
      end

    # CTR opportunities: high impressions, low CTR relative to position
    ctr_opportunities =
      case ClickHouse.query("""
           SELECT
             query,
             sum(clicks) AS total_clicks,
             sum(impressions) AS total_impressions,
             if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
             round(avg(position), 1) AS avg_pos
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - #{days} #{source_filter}
           GROUP BY query
           HAVING sum(impressions) >= 50 AND ctr < 3 AND avg_pos <= 20
           ORDER BY total_impressions DESC
           LIMIT 15
           """) do
        {:ok, rows} -> rows
        _ -> []
      end

    # New keywords (appeared in last 7d, not in prior 7d)
    new_keywords =
      case ClickHouse.query("""
           SELECT query, sum(clicks) AS clicks, sum(impressions) AS impressions,
             round(avg(position), 1) AS avg_pos
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 7 #{source_filter}
             AND query NOT IN (
               SELECT query FROM search_console FINAL
               WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7 #{source_filter}
             )
           GROUP BY query
           HAVING impressions >= 3
           ORDER BY clicks DESC
           LIMIT 15
           """) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Lost keywords (in prior 7d, not in last 7d)
    lost_keywords =
      case ClickHouse.query("""
           SELECT query, sum(clicks) AS clicks, sum(impressions) AS impressions,
             round(avg(position), 1) AS avg_pos
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7 #{source_filter}
             AND query NOT IN (
               SELECT query FROM search_console FINAL
               WHERE site_id = #{site_p} AND date >= today() - 7 #{source_filter}
             )
           GROUP BY query
           HAVING impressions >= 3
           ORDER BY clicks DESC
           LIMIT 15
           """) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Position distribution
    pos_dist =
      case ClickHouse.query("""
           SELECT
             countIf(avg_pos <= 3) AS top3,
             countIf(avg_pos > 3 AND avg_pos <= 10) AS top10,
             countIf(avg_pos > 10 AND avg_pos <= 20) AS top20,
             countIf(avg_pos > 20) AS beyond20
           FROM (
             SELECT query, avg(position) AS avg_pos
             FROM search_console FINAL
             WHERE site_id = #{site_p} AND date >= today() - #{days} #{source_filter}
             GROUP BY query HAVING sum(impressions) >= 1
           )
           """) do
        {:ok, [row | _]} -> row
        _ -> %{}
      end

    socket
    |> assign(:stats, stats)
    |> assign(:queries, queries)
    |> assign(:pages, pages)
    |> assign(:has_data, queries != [])
    |> assign(:query_error, query_error)
    |> assign(:ranking_changes, ranking_changes)
    |> assign(:ctr_opportunities, ctr_opportunities)
    |> assign(:new_keywords, new_keywords)
    |> assign(:lost_keywords, lost_keywords)
    |> assign(:pos_dist, pos_dist)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout flash={@flash} site={@site}>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Search Keywords</h1>
            <p class="text-sm text-gray-500 mt-1">Organic search queries from Google and Bing</p>
          </div>
          <div class="flex items-center gap-3">
            <select
              phx-change="change_source"
              name="source"
              class="text-sm rounded border-gray-300 py-1.5 pr-8"
            >
              <option value="all" selected={@source_filter == "all"}>All Sources</option>
              <option value="google" selected={@source_filter == "google"}>Google</option>
              <option value="bing" selected={@source_filter == "bing"}>Bing</option>
            </select>
            <div class="flex rounded-lg border border-gray-300 overflow-hidden">
              <%= for {val, label} <- [{"7d", "7d"}, {"30d", "30d"}, {"90d", "90d"}] do %>
                <button
                  phx-click="change_range"
                  phx-value-range={val}
                  class={"px-3 py-1.5 text-sm font-medium " <>
                    if(@date_range == val, do: "bg-indigo-600 text-white", else: "bg-white text-gray-700 hover:bg-gray-50")}
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <%= if !@has_data do %>
          <div class="bg-white rounded-lg shadow p-10 text-center">
            <h2 class="text-lg font-semibold text-gray-900 mb-2">No search data yet</h2>
            <p class="text-sm text-gray-600 max-w-md mx-auto mb-4">
              Connect Google Search Console or Bing Webmaster from <.link
                navigate={~p"/dashboard/sites/#{@site.id}/settings"}
                class="text-indigo-600 underline"
              >Site Settings</.link>.
              Data syncs daily with a 2-3 day delay.
            </p>
            <%= if @query_error do %>
              <p class="text-xs text-red-400 mt-2">Error: {@query_error}</p>
            <% end %>
          </div>
        <% else %>
          <%!-- Stats cards --%>
          <div class="grid grid-cols-2 lg:grid-cols-5 gap-4 mb-8">
            <div class="bg-white rounded-lg shadow p-5 border-t-4 border-indigo-500">
              <dt class="text-sm font-medium text-gray-500 mb-1">Clicks</dt>
              <dd class="text-3xl font-bold text-indigo-700">
                {format_number(to_num(@stats["total_clicks"] || "0"))}
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <dt class="text-sm font-medium text-gray-500 mb-1">Impressions</dt>
              <dd class="text-3xl font-bold text-gray-900">
                {format_number(to_num(@stats["total_impressions"] || "0"))}
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <dt class="text-sm font-medium text-gray-500 mb-1">Avg CTR</dt>
              <dd class="text-3xl font-bold text-gray-900">{@stats["avg_ctr"] || "0"}%</dd>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <dt class="text-sm font-medium text-gray-500 mb-1">Avg Position</dt>
              <dd class="text-3xl font-bold text-gray-900">{@stats["avg_position"] || "0"}</dd>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <dt class="text-sm font-medium text-gray-500 mb-1">Unique Queries</dt>
              <dd class="text-3xl font-bold text-gray-900">
                {format_number(to_num(@stats["unique_queries"] || "0"))}
              </dd>
            </div>
          </div>

          <%!-- Top Queries --%>
          <div class="bg-white rounded-lg shadow p-6 mb-8">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">Top Search Queries</h2>
            <div class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-3 text-sm font-semibold text-gray-700">Query</th>
                    <th
                      class="text-right py-3 text-sm font-semibold text-gray-700 cursor-pointer hover:text-indigo-600"
                      phx-click="sort"
                      phx-value-col="total_clicks"
                    >
                      Clicks {sort_arrow("total_clicks", @sort_by, @sort_dir)}
                    </th>
                    <th
                      class="text-right py-3 text-sm font-semibold text-gray-700 cursor-pointer hover:text-indigo-600"
                      phx-click="sort"
                      phx-value-col="total_impressions"
                    >
                      Impressions {sort_arrow("total_impressions", @sort_by, @sort_dir)}
                    </th>
                    <th
                      class="text-right py-3 text-sm font-semibold text-gray-700 cursor-pointer hover:text-indigo-600"
                      phx-click="sort"
                      phx-value-col="ctr"
                    >
                      CTR {sort_arrow("ctr", @sort_by, @sort_dir)}
                    </th>
                    <th
                      class="text-right py-3 text-sm font-semibold text-gray-700 cursor-pointer hover:text-indigo-600"
                      phx-click="sort"
                      phx-value-col="avg_pos"
                    >
                      Position {sort_arrow("avg_pos", @sort_by, @sort_dir)}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <%= for q <- @queries do %>
                    <tr class="border-b border-gray-100 hover:bg-gray-50">
                      <td class="py-3 text-sm font-medium text-gray-900 max-w-md truncate">
                        {q["query"]}
                      </td>
                      <td class="text-right py-3 text-sm font-semibold">
                        {format_number(to_num(q["total_clicks"]))}
                      </td>
                      <td class="text-right py-3 text-sm text-gray-600">
                        {format_number(to_num(q["total_impressions"]))}
                      </td>
                      <td class="text-right py-3 text-sm text-gray-600">{q["ctr"]}%</td>
                      <td class="text-right py-3 text-sm">
                        <span class={"font-medium " <> position_color(to_float(q["avg_pos"]))}>
                          {q["avg_pos"]}
                        </span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Top Pages --%>
          <div class="bg-white rounded-lg shadow p-6">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">Top Pages by Search</h2>
            <div class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-3 text-sm font-semibold text-gray-700">Page</th>
                    <th class="text-right py-3 text-sm font-semibold text-gray-700">Clicks</th>
                    <th class="text-right py-3 text-sm font-semibold text-gray-700">Impressions</th>
                    <th class="text-right py-3 text-sm font-semibold text-gray-700">CTR</th>
                    <th class="text-right py-3 text-sm font-semibold text-gray-700">Avg Position</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for p <- @pages do %>
                    <tr class="border-b border-gray-100 hover:bg-gray-50">
                      <td class="py-3 text-sm text-indigo-600 max-w-md truncate">
                        {extract_path(p["page"])}
                      </td>
                      <td class="text-right py-3 text-sm font-semibold">
                        {format_number(to_num(p["total_clicks"]))}
                      </td>
                      <td class="text-right py-3 text-sm text-gray-600">
                        {format_number(to_num(p["total_impressions"]))}
                      </td>
                      <td class="text-right py-3 text-sm text-gray-600">{p["ctr"]}%</td>
                      <td class="text-right py-3 text-sm">
                        <span class={"font-medium " <> position_color(to_float(p["avg_pos"]))}>
                          {p["avg_pos"]}
                        </span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Position Distribution --%>
          <%= if @pos_dist != %{} do %>
            <div class="bg-white rounded-lg shadow p-6 mb-8">
              <h2 class="text-lg font-semibold text-gray-900 mb-4">Position Distribution</h2>
              <div class="grid grid-cols-4 gap-4">
                <div class="text-center p-3 bg-green-50 rounded-lg">
                  <div class="text-2xl font-bold text-green-700">{format_number(to_num(@pos_dist["top3"] || "0"))}</div>
                  <div class="text-xs text-green-600 mt-1">Top 3</div>
                </div>
                <div class="text-center p-3 bg-blue-50 rounded-lg">
                  <div class="text-2xl font-bold text-blue-700">{format_number(to_num(@pos_dist["top10"] || "0"))}</div>
                  <div class="text-xs text-blue-600 mt-1">4-10</div>
                </div>
                <div class="text-center p-3 bg-amber-50 rounded-lg">
                  <div class="text-2xl font-bold text-amber-700">{format_number(to_num(@pos_dist["top20"] || "0"))}</div>
                  <div class="text-xs text-amber-600 mt-1">11-20</div>
                </div>
                <div class="text-center p-3 bg-red-50 rounded-lg">
                  <div class="text-2xl font-bold text-red-700">{format_number(to_num(@pos_dist["beyond20"] || "0"))}</div>
                  <div class="text-xs text-red-600 mt-1">20+</div>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Ranking Changes --%>
          <%= if @ranking_changes != [] do %>
            <div class="bg-white rounded-lg shadow p-6 mb-8">
              <h2 class="text-lg font-semibold text-gray-900 mb-1">Ranking Changes</h2>
              <p class="text-xs text-gray-500 mb-4">Keywords with significant position changes (last 7 days vs prior 7 days)</p>
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-2 text-sm font-semibold text-gray-700">Query</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Clicks</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Position</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Was</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Change</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for r <- @ranking_changes do %>
                    <% change = to_float(r["pos_change"]) %>
                    <tr class="border-b border-gray-100 hover:bg-gray-50">
                      <td class="py-2 text-sm text-gray-900 max-w-xs truncate">{r["query"]}</td>
                      <td class="text-right py-2 text-sm">{format_number(to_num(r["current_clicks"]))}</td>
                      <td class={"text-right py-2 text-sm font-medium " <> position_color(to_float(r["current_pos"]))}>{r["current_pos"]}</td>
                      <td class="text-right py-2 text-sm text-gray-500">{r["previous_pos"]}</td>
                      <td class={"text-right py-2 text-sm font-bold " <> if(change > 0, do: "text-green-600", else: "text-red-600")}>
                        {if change > 0, do: "+#{r["pos_change"]}", else: r["pos_change"]}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <%!-- CTR Opportunities --%>
          <%= if @ctr_opportunities != [] do %>
            <div class="bg-white rounded-lg shadow p-6 mb-8">
              <h2 class="text-lg font-semibold text-gray-900 mb-1">CTR Opportunities</h2>
              <p class="text-xs text-gray-500 mb-4">High impressions with below-average CTR — improve title/meta description for more clicks</p>
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-2 text-sm font-semibold text-gray-700">Query</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Impressions</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Clicks</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">CTR</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Position</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for r <- @ctr_opportunities do %>
                    <tr class="border-b border-gray-100 hover:bg-gray-50">
                      <td class="py-2 text-sm text-gray-900 max-w-xs truncate">{r["query"]}</td>
                      <td class="text-right py-2 text-sm font-semibold text-amber-600">{format_number(to_num(r["total_impressions"]))}</td>
                      <td class="text-right py-2 text-sm">{format_number(to_num(r["total_clicks"]))}</td>
                      <td class="text-right py-2 text-sm text-red-600 font-medium">{r["ctr"]}%</td>
                      <td class={"text-right py-2 text-sm " <> position_color(to_float(r["avg_pos"]))}>{r["avg_pos"]}</td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <%!-- New & Lost Keywords --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
            <%= if @new_keywords != [] do %>
              <div class="bg-white rounded-lg shadow p-6">
                <h2 class="text-lg font-semibold text-green-700 mb-1">New Keywords</h2>
                <p class="text-xs text-gray-500 mb-4">Appeared in last 7 days, not seen in prior 7 days</p>
                <table class="w-full">
                  <thead>
                    <tr class="border-b border-gray-200">
                      <th class="text-left py-2 text-sm font-semibold text-gray-700">Query</th>
                      <th class="text-right py-2 text-sm font-semibold text-gray-700">Clicks</th>
                      <th class="text-right py-2 text-sm font-semibold text-gray-700">Pos</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for r <- @new_keywords do %>
                      <tr class="border-b border-gray-100">
                        <td class="py-2 text-sm text-gray-900 max-w-[200px] truncate">{r["query"]}</td>
                        <td class="text-right py-2 text-sm font-medium text-green-600">{format_number(to_num(r["clicks"]))}</td>
                        <td class={"text-right py-2 text-sm " <> position_color(to_float(r["avg_pos"]))}>{r["avg_pos"]}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
            <%= if @lost_keywords != [] do %>
              <div class="bg-white rounded-lg shadow p-6">
                <h2 class="text-lg font-semibold text-red-700 mb-1">Lost Keywords</h2>
                <p class="text-xs text-gray-500 mb-4">In prior 7 days but disappeared from last 7 days</p>
                <table class="w-full">
                  <thead>
                    <tr class="border-b border-gray-200">
                      <th class="text-left py-2 text-sm font-semibold text-gray-700">Query</th>
                      <th class="text-right py-2 text-sm font-semibold text-gray-700">Clicks</th>
                      <th class="text-right py-2 text-sm font-semibold text-gray-700">Pos</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for r <- @lost_keywords do %>
                      <tr class="border-b border-gray-100">
                        <td class="py-2 text-sm text-gray-900 max-w-[200px] truncate">{r["query"]}</td>
                        <td class="text-right py-2 text-sm font-medium text-red-600">{format_number(to_num(r["clicks"]))}</td>
                        <td class={"text-right py-2 text-sm " <> position_color(to_float(r["avg_pos"]))}>{r["avg_pos"]}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp sort_arrow(col, sort_by, sort_dir) do
    if col == sort_by do
      if sort_dir == "desc", do: "\u25BC", else: "\u25B2"
    else
      ""
    end
  end

  defp position_color(pos) when pos <= 3, do: "text-green-700"
  defp position_color(pos) when pos <= 10, do: "text-blue-700"
  defp position_color(pos) when pos <= 20, do: "text-amber-600"
  defp position_color(_), do: "text-red-600"

  defp extract_path(nil), do: "/"

  defp extract_path(url) when is_binary(url) do
    case URI.parse(url) do
      %{path: path} when is_binary(path) -> path
      _ -> url
    end
  end

  defp format_number(n) when is_integer(n) and n >= 1000 do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)
end
