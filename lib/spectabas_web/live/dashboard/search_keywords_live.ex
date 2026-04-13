defmodule SpectabasWeb.Dashboard.SearchKeywordsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, ClickHouse}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers, except: [format_number: 1]

  @allowed_sort_cols ~w(total_clicks total_impressions ctr avg_pos)
  @allowed_sort_dirs ~w(asc desc)

  # Industry-average click-through rate by SERP position (Google organic).
  # Used to project the clicks a query would gain if moved to top 3.
  # These numbers are deliberately conservative — the opportunity queue errs
  # toward flagging fewer, higher-value queries rather than noisy small wins.
  @target_ctr_top3 0.12

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Search Keywords - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:source_filter, "all")
        |> assign(:sort_by, "total_clicks")
        |> assign(:sort_dir, "desc")
        |> assign(:drawer_query, nil)
        |> assign(:drawer_timeseries, [])
        |> assign(:drawer_pages, [])
        |> assign(:drawer_devices, [])
        |> assign(:drawer_countries, [])
        |> assign(:drawer_chart_key, nil)
        |> assign(:drawer_clicks_json, "{}")
        |> assign(:drawer_impressions_json, "{}")
        |> assign(:drawer_ctr_json, "{}")
        |> assign(:drawer_position_json, "{}")
        |> assign(:drawer_loading, false)
        |> assign(:expanded_cannibalization, nil)
        |> load_data()

      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:load_drawer, query}, socket) do
    # Only apply if the user hasn't navigated away since clicking.
    if socket.assigns.drawer_query == query do
      {:noreply, load_drawer_data(socket, query)}
    else
      {:noreply, socket}
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

    safe_dir = if new_dir in @allowed_sort_dirs, do: new_dir, else: "desc"
    {:noreply, socket |> assign(:sort_by, col) |> assign(:sort_dir, safe_dir) |> load_data()}
  end

  def handle_event("sort", _params, socket), do: {:noreply, socket}

  def handle_event("open_query", %{"query" => query}, socket) do
    # Set drawer_query first so the drawer DOM renders with chart hooks.
    # Load data + push charts happens after on handle_info, by which time
    # the hooks are mounted client-side.
    send(self(), {:load_drawer, query})
    {:noreply, assign(socket, :drawer_query, query)}
  end

  def handle_event("close_query", _params, socket) do
    {:noreply,
     socket
     |> assign(:drawer_query, nil)
     |> assign(:drawer_timeseries, [])
     |> assign(:drawer_pages, [])
     |> assign(:drawer_devices, [])
     |> assign(:drawer_countries, [])}
  end

  def handle_event("toggle_cannibalization", %{"query" => query}, socket) do
    expanded =
      if socket.assigns.expanded_cannibalization == query, do: nil, else: query

    {:noreply, assign(socket, :expanded_cannibalization, expanded)}
  end

  # ---------------- Data loading (parallelized) ----------------

  defp load_data(socket) do
    site = socket.assigns.site
    site_p = ClickHouse.param(site.id)
    range = socket.assigns.date_range
    source = socket.assigns.source_filter
    sort_by = socket.assigns.sort_by
    sort_dir = socket.assigns.sort_dir
    days = range_to_days(range)
    source_filter = source_filter_sql(source)
    order = "#{sort_by} #{sort_dir}"

    # Fire all queries in parallel. Each returns its own assign key → value.
    # timed/2 logs the elapsed time so we can spot slow/timing-out queries.
    tasks = [
      Task.async(fn ->
        {:stats, timed("stats", fn -> query_stats(site_p, days, source_filter) end)}
      end),
      Task.async(fn ->
        {:queries,
         timed("queries", fn -> query_top_queries(site_p, days, source_filter, order) end)}
      end),
      Task.async(fn ->
        {:pages, timed("pages", fn -> query_top_pages(site_p, days, source_filter, order) end)}
      end),
      Task.async(fn ->
        {:ranking_changes,
         timed("ranking_changes", fn -> query_ranking_changes(site_p, source_filter) end)}
      end),
      Task.async(fn ->
        {:opportunity_queue,
         timed("opportunity_queue", fn -> query_opportunity_queue(site_p, days, source_filter) end)}
      end),
      Task.async(fn ->
        {:new_keywords,
         timed("new_keywords", fn -> query_new_keywords(site_p, source_filter) end)}
      end),
      Task.async(fn ->
        {:lost_keywords,
         timed("lost_keywords", fn -> query_lost_keywords(site_p, source_filter) end)}
      end),
      Task.async(fn ->
        {:pos_dist,
         timed("pos_dist", fn -> query_pos_distribution(site_p, days, source_filter) end)}
      end),
      Task.async(fn ->
        {:daily_trends,
         timed("daily_trends", fn -> query_daily_trends(site_p, days, source_filter) end)}
      end),
      Task.async(fn ->
        {:cannibalization,
         timed("cannibalization", fn -> query_cannibalization(site_p, days, source_filter) end)}
      end)
    ]

    results =
      Enum.reduce(tasks, %{}, fn task, acc ->
        case Task.yield(task, 30_000) || Task.shutdown(task) do
          {:ok, {key, value}} ->
            if key == :daily_trends do
              require Logger
              Logger.notice("[SearchKeywords] daily_trends returned #{length(value)} rows")
            end

            Map.put(acc, key, value)

          _ ->
            require Logger
            Logger.warning("[SearchKeywords] task timed out")
            acc
        end
      end)

    stats = Map.get(results, :stats, %{})
    queries = Map.get(results, :queries, [])
    daily_trends = Map.get(results, :daily_trends, [])

    # Second-phase: per-query sparklines for the top 20 rendered rows.
    top_query_strings = queries |> Enum.take(20) |> Enum.map(& &1["query"])
    sparklines = query_sparklines(site_p, days, source_filter, top_query_strings)

    # Pre-render chart JSON as assigns so data-chart attributes render inline
    # (guaranteed delivery — no push_event race with hook mount). chart_key
    # changes on every load so DOM ids change, which forces the hook to
    # remount with the new data on range/source/sort change.
    {ci_json, ctr_json, pos_json} = build_chart_jsons(daily_trends)

    socket
    |> assign(:stats, stats)
    |> assign(:queries, queries)
    |> assign(:pages, Map.get(results, :pages, []))
    |> assign(:ranking_changes, Map.get(results, :ranking_changes, []))
    |> assign(:opportunity_queue, Map.get(results, :opportunity_queue, []))
    |> assign(:new_keywords, Map.get(results, :new_keywords, []))
    |> assign(:lost_keywords, Map.get(results, :lost_keywords, []))
    |> assign(:pos_dist, Map.get(results, :pos_dist, %{}))
    |> assign(:cannibalization, Map.get(results, :cannibalization, []))
    |> assign(:daily_trends, daily_trends)
    |> assign(:query_sparklines, sparklines)
    |> assign(:chart_key, Integer.to_string(System.unique_integer([:positive])))
    |> assign(:chart_clicks_impressions_json, ci_json)
    |> assign(:chart_ctr_json, ctr_json)
    |> assign(:chart_position_json, pos_json)
    |> assign(
      :has_data,
      to_num(stats["total_clicks"] || "0") > 0 or
        to_num(stats["total_impressions"] || "0") > 0 or
        queries != []
    )
  end

  defp build_chart_jsons(daily_trends) do
    labels = Enum.map(daily_trends, &short_date(&1["date"]))
    clicks = Enum.map(daily_trends, &to_num(&1["clicks"]))
    impressions = Enum.map(daily_trends, &to_num(&1["impressions"]))
    ctr = Enum.map(daily_trends, &to_float(&1["ctr"]))
    position = Enum.map(daily_trends, &to_float(&1["avg_position"]))

    ci =
      Jason.encode!(%{
        labels: labels,
        datasets: [
          %{label: "Impressions", data: impressions, type: "bar", color: "#c7d2fe", y_axis: "y"},
          %{
            label: "Clicks",
            data: clicks,
            type: "line",
            color: "#4338ca",
            fill: true,
            y_axis: "y1"
          }
        ]
      })

    ctr_json =
      Jason.encode!(%{
        labels: labels,
        datasets: [%{label: "CTR %", data: ctr, type: "line", color: "#059669", fill: true}]
      })

    pos_json =
      Jason.encode!(%{
        labels: labels,
        datasets: [%{label: "Avg Position", data: position, type: "line", color: "#d97706"}],
        invert_y: true
      })

    {ci, ctr_json, pos_json}
  end

  # Times a query and logs how long it took (anything over 1s is notable).
  defp timed(name, fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    ms = System.monotonic_time(:millisecond) - t0

    if ms >= 1000 do
      require Logger
      Logger.notice("[SearchKeywords:slow] #{name} took=#{ms}ms")
    end

    result
  end

  # Per-query sparkline JSON lookup (called from the template).
  def query_sparkline_json(sparklines_by_query, query) do
    pairs = Map.get(sparklines_by_query, query, [])
    pairs = Enum.sort_by(pairs, &elem(&1, 0))

    Jason.encode!(%{
      labels: Enum.map(pairs, &short_date(elem(&1, 0))),
      values: Enum.map(pairs, &elem(&1, 1))
    })
  end

  defp load_drawer_data(socket, query) do
    site = socket.assigns.site
    site_p = ClickHouse.param(site.id)
    query_p = ClickHouse.param(query)
    days = range_to_days(socket.assigns.date_range)
    source_filter = source_filter_sql(socket.assigns.source_filter)

    tasks = [
      Task.async(fn ->
        {:drawer_timeseries, query_drawer_timeseries(site_p, query_p, days, source_filter)}
      end),
      Task.async(fn ->
        {:drawer_pages, query_drawer_pages(site_p, query_p, days, source_filter)}
      end),
      Task.async(fn ->
        {:drawer_devices, query_drawer_devices(site_p, query_p, days, source_filter)}
      end),
      Task.async(fn ->
        {:drawer_countries, query_drawer_countries(site_p, query_p, days, source_filter)}
      end)
    ]

    results =
      Enum.reduce(tasks, %{}, fn task, acc ->
        case Task.yield(task, 10_000) || Task.shutdown(task) do
          {:ok, {key, value}} -> Map.put(acc, key, value)
          _ -> acc
        end
      end)

    ts = Map.get(results, :drawer_timeseries, [])
    {clicks_j, imp_j, ctr_j, pos_j} = build_drawer_chart_jsons(ts)

    socket
    |> assign(:drawer_timeseries, ts)
    |> assign(:drawer_pages, Map.get(results, :drawer_pages, []))
    |> assign(:drawer_devices, Map.get(results, :drawer_devices, []))
    |> assign(:drawer_countries, Map.get(results, :drawer_countries, []))
    |> assign(:drawer_chart_key, Integer.to_string(System.unique_integer([:positive])))
    |> assign(:drawer_clicks_json, clicks_j)
    |> assign(:drawer_impressions_json, imp_j)
    |> assign(:drawer_ctr_json, ctr_j)
    |> assign(:drawer_position_json, pos_j)
  end

  defp build_drawer_chart_jsons(timeseries) do
    labels = Enum.map(timeseries, &short_date(&1["date"]))

    clicks =
      Jason.encode!(%{
        labels: labels,
        datasets: [
          %{
            label: "Clicks",
            data: Enum.map(timeseries, &to_num(&1["clicks"])),
            type: "line",
            color: "#4338ca",
            fill: true
          }
        ]
      })

    imp =
      Jason.encode!(%{
        labels: labels,
        datasets: [
          %{
            label: "Impressions",
            data: Enum.map(timeseries, &to_num(&1["impressions"])),
            type: "line",
            color: "#6366f1",
            fill: true
          }
        ]
      })

    ctr =
      Jason.encode!(%{
        labels: labels,
        datasets: [
          %{
            label: "CTR %",
            data: Enum.map(timeseries, &to_float(&1["ctr"])),
            type: "line",
            color: "#059669",
            fill: true
          }
        ]
      })

    pos =
      Jason.encode!(%{
        labels: labels,
        datasets: [
          %{
            label: "Avg Position",
            data: Enum.map(timeseries, &to_float(&1["avg_position"])),
            type: "line",
            color: "#d97706"
          }
        ],
        invert_y: true
      })

    {clicks, imp, ctr, pos}
  end

  # ---------------- Query functions ----------------

  defp query_stats(site_p, days, source_filter) do
    sql = """
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

    case ClickHouse.query(sql) do
      {:ok, [row | _]} -> row
      _ -> %{}
    end
  end

  defp query_top_queries(site_p, days, source_filter, order) do
    sql = """
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

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_top_pages(site_p, days, source_filter, order) do
    sql = """
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

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_ranking_changes(site_p, source_filter) do
    sql = """
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
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  # Queries at position 8-20 with meaningful impressions, ranked by projected
  # additional clicks if moved into the top 3. This is more actionable than
  # the previous "low CTR" heuristic because it surfaces queries where an
  # SEO win would translate to a lot of extra traffic.
  defp query_opportunity_queue(site_p, days, source_filter) do
    sql = """
    SELECT
      query,
      sum(clicks) AS total_clicks,
      sum(impressions) AS total_impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_pos,
      toUInt32(greatest(0, round(
        sum(impressions) * (#{@target_ctr_top3} - if(sum(impressions) > 0, sum(clicks) / sum(impressions), 0))
      ))) AS projected_gain
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      AND query != ''
      #{source_filter}
    GROUP BY query
    HAVING sum(impressions) >= 50 AND avg_pos >= 8 AND avg_pos <= 20
    ORDER BY projected_gain DESC
    LIMIT 20
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_new_keywords(site_p, source_filter) do
    sql = """
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
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_lost_keywords(site_p, source_filter) do
    sql = """
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
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_pos_distribution(site_p, days, source_filter) do
    sql = """
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
    """

    case ClickHouse.query(sql) do
      {:ok, [row | _]} -> row
      _ -> %{}
    end
  end

  # Per-day totals across all queries. Drives the three trend charts at the
  # top of the page (clicks+impressions combo, CTR, position).
  defp query_daily_trends(site_p, days, source_filter) do
    # FINAL on a 6M+ row search_console table with GROUP BY date was returning
    # 0 rows (query likely exceeded ClickHouse's default 10s max_execution_time
    # within the HTTP client but returning 200 with empty body).
    #
    # Dropped FINAL: search_console is ReplacingMergeTree keyed by
    # (site_id, date, query, page, country, device, source). Dedup happens on
    # merge; without FINAL we might over-count very briefly between syncs, but
    # for a trend chart the per-day sums are stable enough. The raw stats card
    # does its own FINAL aggregate for exact numbers.
    sql = """
    SELECT
      toString(date) AS date,
      sum(clicks) AS clicks,
      sum(impressions) AS impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_position
    FROM search_console
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      #{source_filter}
    GROUP BY date
    ORDER BY date ASC
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        rows

      {:error, err} ->
        require Logger

        Logger.error(
          "[SearchKeywords] daily_trends error: #{inspect(err) |> String.slice(0, 300)}"
        )

        []
    end
  end

  # One row per (top_query, date) over the given range. Used to populate
  # per-query sparklines in the Top Queries table. Returns %{query => [clicks]}
  # aligned to the same date sequence used for the trend charts.
  defp query_sparklines(_site_p, _days, _source_filter, []), do: %{}

  defp query_sparklines(site_p, days, source_filter, queries) do
    in_clause = Enum.map_join(queries, ", ", &ClickHouse.param/1)

    # FINAL dropped here too — same reason as daily_trends.
    sql = """
    SELECT query, toString(date) AS date, sum(clicks) AS clicks
    FROM search_console
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      AND query IN (#{in_clause})
      #{source_filter}
    GROUP BY query, date
    ORDER BY date ASC
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.group_by(rows, & &1["query"], &{&1["date"], to_num(&1["clicks"])})

      _ ->
        %{}
    end
  end

  # Queries where 3+ pages rank in the top 30 with meaningful impressions —
  # an indicator that Google is splitting authority across duplicate content.
  # Returns pages/positions/impressions/clicks as parallel arrays.
  defp query_cannibalization(site_p, days, source_filter) do
    sql = """
    SELECT
      query,
      count() AS page_count,
      sum(clicks) AS total_clicks,
      sum(imps) AS total_impressions,
      groupArray(page) AS pages,
      groupArray(round(pos, 1)) AS positions,
      groupArray(imps) AS page_impressions,
      groupArray(clicks) AS page_clicks
    FROM (
      SELECT
        query, page,
        sum(clicks) AS clicks,
        sum(impressions) AS imps,
        avg(position) AS pos
      FROM search_console FINAL
      WHERE site_id = #{site_p}
        AND date >= today() - #{days}
        AND query != ''
        #{source_filter}
      GROUP BY query, page
      HAVING imps >= 10 AND pos <= 30
    )
    GROUP BY query
    HAVING page_count >= 3
    ORDER BY total_impressions DESC
    LIMIT 15
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.map(rows, fn r ->
          Map.merge(r, %{
            "pages_zip" =>
              Enum.zip([
                ensure_list(r["pages"]),
                ensure_list(r["positions"]),
                ensure_list(r["page_impressions"]),
                ensure_list(r["page_clicks"])
              ])
          })
        end)

      _ ->
        []
    end
  end

  defp ensure_list(nil), do: []
  defp ensure_list(l) when is_list(l), do: l
  defp ensure_list(_), do: []

  # ---------------- Drawer queries ----------------

  defp query_drawer_timeseries(site_p, query_p, days, source_filter) do
    sql = """
    SELECT
      toString(date) AS date,
      sum(clicks) AS clicks,
      sum(impressions) AS impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_position
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND query = #{query_p}
      AND date >= today() - #{days}
      #{source_filter}
    GROUP BY date
    ORDER BY date ASC
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_drawer_pages(site_p, query_p, days, source_filter) do
    sql = """
    SELECT
      page,
      sum(clicks) AS clicks,
      sum(impressions) AS impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_pos
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND query = #{query_p}
      AND date >= today() - #{days}
      #{source_filter}
    GROUP BY page
    ORDER BY impressions DESC
    LIMIT 20
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_drawer_devices(site_p, query_p, days, source_filter) do
    sql = """
    SELECT
      device,
      sum(clicks) AS clicks,
      sum(impressions) AS impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_pos
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND query = #{query_p}
      AND date >= today() - #{days}
      AND device != ''
      #{source_filter}
    GROUP BY device
    ORDER BY impressions DESC
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_drawer_countries(site_p, query_p, days, source_filter) do
    sql = """
    SELECT
      country,
      sum(clicks) AS clicks,
      sum(impressions) AS impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_pos
    FROM search_console FINAL
    WHERE site_id = #{site_p}
      AND query = #{query_p}
      AND date >= today() - #{days}
      AND country != ''
      #{source_filter}
    GROUP BY country
    ORDER BY impressions DESC
    LIMIT 10
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  # ---------------- Render ----------------

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout flash={@flash} site={@site} active="search-keywords">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Search Keywords</h1>
            <p class="text-sm text-gray-500 mt-1">Organic search queries from Google and Bing</p>
          </div>
          <div class="flex items-center gap-3">
            <form phx-change="change_source">
              <select name="source" class="text-sm rounded border-gray-300 py-1.5 pr-8">
                <option value="all" selected={@source_filter == "all"}>All Sources</option>
                <option value="google" selected={@source_filter == "google"}>Google</option>
                <option value="bing" selected={@source_filter == "bing"}>Bing</option>
              </select>
            </form>
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
              >Site Settings</.link>. Data syncs daily with a 2-3 day delay.
            </p>
          </div>
        <% else %>
          <%!-- Stats cards --%>
          <div class="grid grid-cols-2 lg:grid-cols-5 gap-4 mb-6">
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

          <%!-- Trend charts (data in data-chart attr; id changes each reload so the
          element is replaced on range change and hook remounts fresh) --%>
          <div class="bg-white rounded-lg shadow p-6 mb-4">
            <h2 class="text-sm font-semibold text-gray-700 mb-3">Clicks &amp; Impressions</h2>
            <div
              id={"chart-clicks-impressions-" <> @chart_key}
              phx-hook="SearchChart"
              phx-update="ignore"
              data-chart={@chart_clicks_impressions_json}
              class="h-64 relative"
            >
              <canvas></canvas>
            </div>
          </div>

          <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-8">
            <div class="bg-white rounded-lg shadow p-6">
              <h2 class="text-sm font-semibold text-gray-700 mb-3">Avg CTR</h2>
              <div
                id={"chart-ctr-" <> @chart_key}
                phx-hook="SearchChart"
                phx-update="ignore"
                data-chart={@chart_ctr_json}
                class="h-48 relative"
              >
                <canvas></canvas>
              </div>
            </div>
            <div class="bg-white rounded-lg shadow p-6">
              <h2 class="text-sm font-semibold text-gray-700 mb-3">
                Avg Position <span class="text-xs font-normal text-gray-500">(lower is better)</span>
              </h2>
              <div
                id={"chart-position-" <> @chart_key}
                phx-hook="SearchChart"
                phx-update="ignore"
                data-chart={@chart_position_json}
                class="h-48 relative"
              >
                <canvas></canvas>
              </div>
            </div>
          </div>

          <%!-- Top Queries with sparklines --%>
          <div class="bg-white rounded-lg shadow p-6 mb-8">
            <h2 class="text-lg font-semibold text-gray-900 mb-1">Top Search Queries</h2>
            <p class="text-xs text-gray-500 mb-4">
              Click a row to see per-query history, ranking pages, device and country breakdowns.
            </p>
            <div class="overflow-x-auto">
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-3 text-sm font-semibold text-gray-700">Query</th>
                    <th class="text-left py-3 text-sm font-semibold text-gray-700 w-28">Trend</th>
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
                  <%= for {q, idx} <- Enum.with_index(@queries) do %>
                    <tr
                      class="border-b border-gray-100 hover:bg-indigo-50 cursor-pointer"
                      phx-click="open_query"
                      phx-value-query={q["query"]}
                    >
                      <td class="py-3 text-sm font-medium text-gray-900 max-w-md truncate">
                        {q["query"]}
                      </td>
                      <td class="py-2">
                        <%= if idx < 20 do %>
                          <div
                            id={query_sparkline_id(q["query"]) <> "-" <> @chart_key}
                            phx-hook="Sparkline"
                            phx-update="ignore"
                            data-spark={query_sparkline_json(@query_sparklines, q["query"])}
                            class="w-24 h-8"
                          >
                            <canvas></canvas>
                          </div>
                        <% end %>
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

          <%!-- Opportunity Queue --%>
          <%= if @opportunity_queue != [] do %>
            <div class="bg-white rounded-lg shadow p-6 mb-8">
              <h2 class="text-lg font-semibold text-gray-900 mb-1">Opportunity Queue</h2>
              <p class="text-xs text-gray-500 mb-4">
                Queries ranking 8-20 with significant impressions — ordered by projected extra clicks
                if moved to the top 3.
              </p>
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-2 text-sm font-semibold text-gray-700">Query</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Impressions</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Current CTR</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Position</th>
                    <th class="text-right py-2 text-sm font-semibold text-emerald-700">
                      Projected Extra Clicks
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <%= for r <- @opportunity_queue do %>
                    <tr
                      class="border-b border-gray-100 hover:bg-emerald-50 cursor-pointer"
                      phx-click="open_query"
                      phx-value-query={r["query"]}
                    >
                      <td class="py-2 text-sm text-gray-900 max-w-xs truncate">{r["query"]}</td>
                      <td class="text-right py-2 text-sm">
                        {format_number(to_num(r["total_impressions"]))}
                      </td>
                      <td class="text-right py-2 text-sm text-gray-600">{r["ctr"]}%</td>
                      <td class={"text-right py-2 text-sm " <> position_color(to_float(r["avg_pos"]))}>
                        {r["avg_pos"]}
                      </td>
                      <td class="text-right py-2 text-sm font-bold text-emerald-600">
                        +{format_number(to_num(r["projected_gain"]))}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <%!-- Cannibalization --%>
          <%= if @cannibalization != [] do %>
            <div class="bg-white rounded-lg shadow p-6 mb-8">
              <h2 class="text-lg font-semibold text-gray-900 mb-1">Keyword Cannibalization</h2>
              <p class="text-xs text-gray-500 mb-4">
                Queries where 3+ pages compete in the top 30 — usually a duplicate-content
                or internal-linking signal. Click a row to see which pages are fighting.
              </p>
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-2 text-sm font-semibold text-gray-700">Query</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Pages</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Impressions</th>
                    <th class="text-right py-2 text-sm font-semibold text-gray-700">Clicks</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for c <- @cannibalization do %>
                    <tr
                      class="border-b border-gray-100 hover:bg-amber-50 cursor-pointer"
                      phx-click="toggle_cannibalization"
                      phx-value-query={c["query"]}
                    >
                      <td class="py-2 text-sm text-gray-900 max-w-xs truncate">
                        {c["query"]}
                      </td>
                      <td class="text-right py-2 text-sm font-semibold text-amber-600">
                        {c["page_count"]}
                      </td>
                      <td class="text-right py-2 text-sm">
                        {format_number(to_num(c["total_impressions"]))}
                      </td>
                      <td class="text-right py-2 text-sm">
                        {format_number(to_num(c["total_clicks"]))}
                      </td>
                    </tr>
                    <%= if @expanded_cannibalization == c["query"] do %>
                      <tr class="bg-amber-50/50">
                        <td colspan="4" class="px-4 py-3">
                          <table class="w-full text-xs">
                            <thead>
                              <tr class="text-gray-600">
                                <th class="text-left pb-1">Page</th>
                                <th class="text-right pb-1">Position</th>
                                <th class="text-right pb-1">Impressions</th>
                                <th class="text-right pb-1">Clicks</th>
                              </tr>
                            </thead>
                            <tbody>
                              <%= for {page, pos, imps, clicks} <- c["pages_zip"] do %>
                                <tr>
                                  <td class="py-0.5 text-indigo-700 truncate max-w-lg">
                                    {extract_path(page)}
                                  </td>
                                  <td class={"text-right py-0.5 " <> position_color(to_float(pos))}>
                                    {pos}
                                  </td>
                                  <td class="text-right py-0.5 text-gray-700">
                                    {format_number(to_num(imps))}
                                  </td>
                                  <td class="text-right py-0.5 text-gray-700">
                                    {format_number(to_num(clicks))}
                                  </td>
                                </tr>
                              <% end %>
                            </tbody>
                          </table>
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <%!-- Top Pages --%>
          <div class="bg-white rounded-lg shadow p-6 mb-8">
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
                  <div class="text-2xl font-bold text-green-700">
                    {format_number(to_num(@pos_dist["top3"] || "0"))}
                  </div>
                  <div class="text-xs text-green-600 mt-1">Top 3</div>
                </div>
                <div class="text-center p-3 bg-blue-50 rounded-lg">
                  <div class="text-2xl font-bold text-blue-700">
                    {format_number(to_num(@pos_dist["top10"] || "0"))}
                  </div>
                  <div class="text-xs text-blue-600 mt-1">4-10</div>
                </div>
                <div class="text-center p-3 bg-amber-50 rounded-lg">
                  <div class="text-2xl font-bold text-amber-700">
                    {format_number(to_num(@pos_dist["top20"] || "0"))}
                  </div>
                  <div class="text-xs text-amber-600 mt-1">11-20</div>
                </div>
                <div class="text-center p-3 bg-red-50 rounded-lg">
                  <div class="text-2xl font-bold text-red-700">
                    {format_number(to_num(@pos_dist["beyond20"] || "0"))}
                  </div>
                  <div class="text-xs text-red-600 mt-1">20+</div>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Ranking Changes --%>
          <%= if @ranking_changes != [] do %>
            <div class="bg-white rounded-lg shadow p-6 mb-8">
              <h2 class="text-lg font-semibold text-gray-900 mb-1">Ranking Changes</h2>
              <p class="text-xs text-gray-500 mb-4">
                Keywords with significant position changes (last 7 days vs prior 7 days)
              </p>
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
                    <tr
                      class="border-b border-gray-100 hover:bg-gray-50 cursor-pointer"
                      phx-click="open_query"
                      phx-value-query={r["query"]}
                    >
                      <td class="py-2 text-sm text-gray-900 max-w-xs truncate">{r["query"]}</td>
                      <td class="text-right py-2 text-sm">
                        {format_number(to_num(r["current_clicks"]))}
                      </td>
                      <td class={"text-right py-2 text-sm font-medium " <> position_color(to_float(r["current_pos"]))}>
                        {r["current_pos"]}
                      </td>
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

          <%!-- New & Lost Keywords --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-8 mb-8">
            <%= if @new_keywords != [] do %>
              <div class="bg-white rounded-lg shadow p-6">
                <h2 class="text-lg font-semibold text-green-700 mb-1">New Keywords</h2>
                <p class="text-xs text-gray-500 mb-4">
                  Appeared in last 7 days, not seen in prior 7 days
                </p>
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
                      <tr
                        class="border-b border-gray-100 cursor-pointer hover:bg-green-50"
                        phx-click="open_query"
                        phx-value-query={r["query"]}
                      >
                        <td class="py-2 text-sm text-gray-900 max-w-[200px] truncate">
                          {r["query"]}
                        </td>
                        <td class="text-right py-2 text-sm font-medium text-green-600">
                          {format_number(to_num(r["clicks"]))}
                        </td>
                        <td class={"text-right py-2 text-sm " <> position_color(to_float(r["avg_pos"]))}>
                          {r["avg_pos"]}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
            <%= if @lost_keywords != [] do %>
              <div class="bg-white rounded-lg shadow p-6">
                <h2 class="text-lg font-semibold text-red-700 mb-1">Lost Keywords</h2>
                <p class="text-xs text-gray-500 mb-4">
                  In prior 7 days but disappeared from last 7 days
                </p>
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
                        <td class="py-2 text-sm text-gray-900 max-w-[200px] truncate">
                          {r["query"]}
                        </td>
                        <td class="text-right py-2 text-sm font-medium text-red-600">
                          {format_number(to_num(r["clicks"]))}
                        </td>
                        <td class={"text-right py-2 text-sm " <> position_color(to_float(r["avg_pos"]))}>
                          {r["avg_pos"]}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Query detail drawer --%>
      <%= if @drawer_query do %>
        <div
          class="fixed inset-0 bg-gray-900/40 z-40"
          phx-click="close_query"
          aria-hidden="true"
        >
        </div>
        <div class="fixed inset-y-0 right-0 z-50 w-full max-w-2xl bg-white shadow-2xl overflow-y-auto">
          <div class="sticky top-0 bg-white border-b border-gray-200 px-6 py-4 flex items-start justify-between">
            <div class="min-w-0 flex-1 pr-4">
              <p class="text-xs text-gray-500">Query</p>
              <h3 class="text-lg font-semibold text-gray-900 break-words">{@drawer_query}</h3>
            </div>
            <button
              phx-click="close_query"
              class="shrink-0 text-gray-400 hover:text-gray-700 text-xl"
              aria-label="Close"
            >
              &times;
            </button>
          </div>

          <div class="px-6 py-4 space-y-6">
            <%!-- 4 stacked per-query time series (loaded on click; ids vary by
            drawer_chart_key so hooks remount fresh on each open/reopen) --%>
            <%= if @drawer_chart_key do %>
              <div>
                <h4 class="text-sm font-semibold text-gray-700 mb-2">Clicks</h4>
                <div
                  id={"drawer-chart-clicks-" <> @drawer_chart_key}
                  phx-hook="SearchChart"
                  phx-update="ignore"
                  data-chart={@drawer_clicks_json}
                  class="h-32 relative"
                >
                  <canvas></canvas>
                </div>
              </div>
              <div>
                <h4 class="text-sm font-semibold text-gray-700 mb-2">Impressions</h4>
                <div
                  id={"drawer-chart-impressions-" <> @drawer_chart_key}
                  phx-hook="SearchChart"
                  phx-update="ignore"
                  data-chart={@drawer_impressions_json}
                  class="h-32 relative"
                >
                  <canvas></canvas>
                </div>
              </div>
              <div>
                <h4 class="text-sm font-semibold text-gray-700 mb-2">CTR</h4>
                <div
                  id={"drawer-chart-ctr-" <> @drawer_chart_key}
                  phx-hook="SearchChart"
                  phx-update="ignore"
                  data-chart={@drawer_ctr_json}
                  class="h-32 relative"
                >
                  <canvas></canvas>
                </div>
              </div>
              <div>
                <h4 class="text-sm font-semibold text-gray-700 mb-2">Position</h4>
                <div
                  id={"drawer-chart-position-" <> @drawer_chart_key}
                  phx-hook="SearchChart"
                  phx-update="ignore"
                  data-chart={@drawer_position_json}
                  class="h-32 relative"
                >
                  <canvas></canvas>
                </div>
              </div>
            <% else %>
              <div class="text-center py-8 text-sm text-gray-500">Loading...</div>
            <% end %>

            <%!-- Pages ranking for this query --%>
            <div>
              <h4 class="text-sm font-semibold text-gray-700 mb-2">Pages Ranking for This Query</h4>
              <%= if @drawer_pages == [] do %>
                <p class="text-sm text-gray-500 italic">No data.</p>
              <% else %>
                <table class="w-full text-sm">
                  <thead>
                    <tr class="text-gray-600 border-b border-gray-200">
                      <th class="text-left py-1 font-medium">Page</th>
                      <th class="text-right py-1 font-medium">Clicks</th>
                      <th class="text-right py-1 font-medium">Impr</th>
                      <th class="text-right py-1 font-medium">CTR</th>
                      <th class="text-right py-1 font-medium">Pos</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for p <- @drawer_pages do %>
                      <tr class="border-b border-gray-50">
                        <td class="py-1.5 text-indigo-700 truncate max-w-xs">
                          {extract_path(p["page"])}
                        </td>
                        <td class="text-right py-1.5">{format_number(to_num(p["clicks"]))}</td>
                        <td class="text-right py-1.5 text-gray-600">
                          {format_number(to_num(p["impressions"]))}
                        </td>
                        <td class="text-right py-1.5 text-gray-600">{p["ctr"]}%</td>
                        <td class={"text-right py-1.5 " <> position_color(to_float(p["avg_pos"]))}>
                          {p["avg_pos"]}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>

            <%!-- Device split --%>
            <%= if @drawer_devices != [] do %>
              <div>
                <h4 class="text-sm font-semibold text-gray-700 mb-2">Devices</h4>
                <table class="w-full text-sm">
                  <thead>
                    <tr class="text-gray-600 border-b border-gray-200">
                      <th class="text-left py-1 font-medium">Device</th>
                      <th class="text-right py-1 font-medium">Clicks</th>
                      <th class="text-right py-1 font-medium">Impr</th>
                      <th class="text-right py-1 font-medium">CTR</th>
                      <th class="text-right py-1 font-medium">Pos</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for d <- @drawer_devices do %>
                      <tr class="border-b border-gray-50">
                        <td class="py-1.5 capitalize text-gray-900">{d["device"]}</td>
                        <td class="text-right py-1.5">{format_number(to_num(d["clicks"]))}</td>
                        <td class="text-right py-1.5 text-gray-600">
                          {format_number(to_num(d["impressions"]))}
                        </td>
                        <td class="text-right py-1.5 text-gray-600">{d["ctr"]}%</td>
                        <td class={"text-right py-1.5 " <> position_color(to_float(d["avg_pos"]))}>
                          {d["avg_pos"]}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- Country split --%>
            <%= if @drawer_countries != [] do %>
              <div>
                <h4 class="text-sm font-semibold text-gray-700 mb-2">Countries</h4>
                <table class="w-full text-sm">
                  <thead>
                    <tr class="text-gray-600 border-b border-gray-200">
                      <th class="text-left py-1 font-medium">Country</th>
                      <th class="text-right py-1 font-medium">Clicks</th>
                      <th class="text-right py-1 font-medium">Impr</th>
                      <th class="text-right py-1 font-medium">CTR</th>
                      <th class="text-right py-1 font-medium">Pos</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for c <- @drawer_countries do %>
                      <tr class="border-b border-gray-50">
                        <td class="py-1.5 uppercase text-gray-900">{c["country"]}</td>
                        <td class="text-right py-1.5">{format_number(to_num(c["clicks"]))}</td>
                        <td class="text-right py-1.5 text-gray-600">
                          {format_number(to_num(c["impressions"]))}
                        </td>
                        <td class="text-right py-1.5 text-gray-600">{c["ctr"]}%</td>
                        <td class={"text-right py-1.5 " <> position_color(to_float(c["avg_pos"]))}>
                          {c["avg_pos"]}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </.dashboard_layout>
    """
  end

  # ---------------- Helpers ----------------

  defp sort_arrow(col, sort_by, sort_dir) do
    if col == sort_by do
      if sort_dir == "desc", do: "\u25BC", else: "\u25B2"
    else
      ""
    end
  end

  defp position_color(pos) when is_number(pos) and pos <= 3, do: "text-green-700"
  defp position_color(pos) when is_number(pos) and pos <= 10, do: "text-blue-700"
  defp position_color(pos) when is_number(pos) and pos <= 20, do: "text-amber-600"
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

  defp range_to_days("7d"), do: 7
  defp range_to_days("30d"), do: 30
  defp range_to_days("90d"), do: 90
  defp range_to_days(_), do: 30

  defp source_filter_sql("google"), do: "AND source = 'google'"
  defp source_filter_sql("bing"), do: "AND source = 'bing'"
  defp source_filter_sql(_), do: ""

  defp short_date(nil), do: ""

  defp short_date(d) when is_binary(d) do
    case String.split(d, "-") do
      [_y, m, day] -> "#{m}/#{day}"
      _ -> d
    end
  end

  defp short_date(d), do: to_string(d)

  # DOM id for a per-query sparkline. Query can contain anything; hex-encode
  # to guarantee a valid id.
  defp query_sparkline_id(query) do
    "qspark-" <> Base.encode16(query, case: :lower)
  end
end
