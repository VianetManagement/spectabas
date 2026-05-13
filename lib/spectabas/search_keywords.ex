defmodule Spectabas.SearchKeywords do
  @moduledoc """
  ClickHouse queries that back the Search Keywords dashboard (GSC + Bing
  search-console data, stored in the `search_console` table).

  Functions here used to live as private helpers inside
  `SpectabasWeb.Dashboard.SearchKeywordsLive`. They were lifted into a
  context module so the hourly `DashboardSnapshot` worker can call them
  too — the dashboard reads its default config (30d, all sources,
  clicks-desc sort) from PG instead of fanning out 10+ CH queries on
  every page mount.

  All functions take a `site_id` integer and a `source` filter string
  (`"all"`, `"google"`, `"bing"`); the LiveView and worker hand them in
  raw and this module owns parameterization + the SQL fragment.
  """

  alias Spectabas.ClickHouse
  import Spectabas.TypeHelpers

  # Industry-average click-through rate by SERP position (Google organic).
  # Used to project the clicks a query would gain if moved to top 3.
  @target_ctr_top3 0.12

  @doc "Default sort order string the LiveView uses on first load."
  def default_order, do: "total_clicks desc"

  @doc "Default config tuple — used by the snapshot writer and the read path."
  def default_config, do: {30, "all", "total_clicks", "desc"}

  defp source_filter_sql("google"), do: "AND source = 'google'"
  defp source_filter_sql("bing"), do: "AND source = 'bing'"
  defp source_filter_sql(_), do: ""

  defp site_param(site_id), do: ClickHouse.param(site_id)

  def query_stats(site_id, days, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, [row | _]} -> row
      _ -> %{}
    end
  end

  def query_top_queries(site_id, days, source, order) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  def query_top_pages(site_id, days, source, order) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  def query_ranking_changes(site_id, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  # Queries at position 8-20 with meaningful impressions, ranked by projected
  # additional clicks if moved into the top 3. More actionable than a "low
  # CTR" heuristic because it surfaces queries where an SEO win would
  # translate to a lot of extra traffic.
  def query_opportunity_queue(site_id, days, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  def query_new_keywords(site_id, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  def query_lost_keywords(site_id, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  def query_pos_distribution(site_id, days, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
      {:ok, [row | _]} -> row
      _ -> %{}
    end
  end

  # Per-day totals across all queries. Drives the three trend charts at the
  # top of the page (clicks+impressions combo, CTR, position).
  # Aliases MUST NOT shadow column names — `sum(clicks) AS clicks` resolves
  # the inner `sum(clicks)` to `sum(alias)` = nested agg → ILLEGAL_AGGREGATION;
  # `toString(date) AS date` makes `GROUP BY date` ambiguous between the
  # Date column and the String alias → NO_COMMON_TYPE. Renamed to
  # total_clicks / total_impressions / bucket.
  # FINAL is skipped — with 6M+ rows, FINAL + GROUP BY date silently returns
  # 0 rows. Stats card uses FINAL for exact aggregate numbers.
  def query_daily_trends(site_id, days, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

    sql = """
    SELECT
      toString(date) AS bucket,
      sum(clicks) AS total_clicks,
      sum(impressions) AS total_impressions,
      if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
      round(avg(position), 1) AS avg_position
    FROM search_console
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      #{source_filter}
    GROUP BY date
    ORDER BY date ASC
    """

    case ch_query(sql) do
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

  @doc """
  Per-query daily click sparklines for the given list of queries. Returns
  `%{query => [{bucket, clicks}, ...]}` aligned to the same date sequence
  used for the trend charts.
  """
  def query_sparklines(_site_id, _days, _source, []), do: %{}

  def query_sparklines(site_id, days, source, queries) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)
    in_clause = Enum.map_join(queries, ", ", &ClickHouse.param/1)

    # FINAL dropped + alias renamed to avoid shadowing the Date column.
    sql = """
    SELECT query, toString(date) AS bucket, sum(clicks) AS total_clicks
    FROM search_console
    WHERE site_id = #{site_p}
      AND date >= today() - #{days}
      AND query IN (#{in_clause})
      #{source_filter}
    GROUP BY query, date
    ORDER BY date ASC
    """

    case ch_query(sql) do
      {:ok, rows} ->
        Enum.group_by(rows, & &1["query"], &{&1["bucket"], to_num(&1["total_clicks"])})

      _ ->
        %{}
    end
  end

  # Queries where 3+ pages rank in the top 30 with meaningful impressions —
  # an indicator that Google is splitting authority across duplicate content.
  # Returns pages/positions/impressions/clicks as parallel arrays.
  def query_cannibalization(site_id, days, source) do
    site_p = site_param(site_id)
    source_filter = source_filter_sql(source)

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

    case ch_query(sql) do
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

  # Every query in this module either FINALs over `search_console` (heavy
  # dedup at query time) or scans 6M+ rows for daily_trends/sparklines.
  # The ClickHouse module's default 30s HTTP receive_timeout is far too
  # short — on puppies.com these silently return {:error, _} and the
  # snapshot kind never gets written. Match the established 200_000ms
  # pattern used by do_funnel_stats / do_goal_completions, with a 180s
  # SQL ceiling on top to bound CPU per query.
  defp ch_query(sql) do
    ClickHouse.query(sql <> "\nSETTINGS max_execution_time = 180", receive_timeout: 200_000)
  end
end
