defmodule Spectabas.AI.InsightsPrompt do
  @moduledoc """
  Builds the prompt for AI-powered weekly insights analysis.
  Gathers aggregated metrics from all data sources and formats them
  for the AI provider. Never sends raw visitor data — only aggregates.
  """

  alias Spectabas.{ClickHouse, Analytics, Goals}
  alias Spectabas.Analytics.AnomalyDetector
  import Spectabas.TypeHelpers, only: [to_num: 1, to_float: 1]
  require Logger

  @system_prompt """
  You are an analytics advisor for a website. You analyze weekly metrics and provide
  concrete, actionable recommendations. Be specific and prioritize by impact.

  Format your response as markdown with these sections:
  ## Executive Summary
  2-3 sentence overview of the week.

  ## Priority Actions
  Numbered list of the most impactful things to do this week, with specific data points.

  ## SEO Insights
  Keyword and search ranking observations with specific recommendations.

  ## Traffic & Engagement
  Notable patterns in visitor behavior, pages, sources, devices, geography.

  ## Revenue & Advertising
  Revenue trends and ad performance observations (only if data exists).

  ## Conversion & Goals
  Goal performance, funnel bottlenecks, and click element insights (only if data exists).

  Keep it concise — under 1000 words total. Use specific numbers from the data.
  If a section has no relevant data, skip it entirely.
  Focus on CHANGES and ACTIONABLE items, not just restating the numbers.
  """

  def system_prompt, do: @system_prompt

  @doc "Build the user prompt with all gathered metrics for a site."
  def build(site, user) do
    site_p = ClickHouse.param(site.id)

    anomaly_section =
      case AnomalyDetector.detect(site, user) do
        {:ok, results} when results != [] ->
          text =
            results
            |> Enum.map(fn a -> "- [#{a.severity}] #{a.category}: #{a.message}" end)
            |> Enum.join("\n")

          "## Detected Anomalies (last 7 days vs prior 7 days)\n#{text}"

        _ ->
          nil
      end

    sections =
      [
        anomaly_section,
        with_header("Traffic Summary (7d vs prior 7d)", query_traffic_summary(site_p)),
        with_header("Engagement Metrics", query_engagement(site_p)),
        with_header("Top 10 Pages by Pageviews", query_top_pages(site_p)),
        with_header("Top 5 Traffic Sources", query_top_sources(site_p)),
        with_header("Top 5 Countries", query_top_countries(site_p)),
        with_header("Device Split", query_device_split(site_p)),
        with_header("Search Console (last 7 days)", query_gsc_summary(site_p)),
        with_header("Top 10 Search Queries", query_top_queries(site_p)),
        with_header("New Keywords (appeared this week)", query_new_keywords(site_p)),
        with_header("Revenue (7d vs prior 7d)", query_revenue_summary(site_p)),
        with_header("Ad Spend by Platform", query_ad_spend_summary(site_p)),
        with_header("Scraper Activity", query_scraper_summary(site_p)),
        with_header("Goal Performance (7d vs prior 7d)", query_goal_performance(site, user)),
        with_header("Funnel Drop-off Analysis", query_funnel_analysis(site, user)),
        with_header("Top Clicked Elements (7d)", query_click_elements(site_p)),
        with_header("Suggested Conversion Paths", query_suggested_paths(site, user))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    """
    Analyze this website's performance data and provide actionable recommendations.
    Site: #{site.name} (#{site.domain})

    #{sections}
    """
    |> String.trim()
  end

  defp query_traffic_summary(site_p) do
    case ClickHouse.query("""
         SELECT
           sum(if(timestamp >= now() - INTERVAL 7 DAY, 1, 0)) AS cur_pv,
           sum(if(timestamp < now() - INTERVAL 7 DAY, 1, 0)) AS prev_pv,
           uniqExactIf(visitor_id, timestamp >= now() - INTERVAL 7 DAY) AS cur_visitors,
           uniqExactIf(visitor_id, timestamp < now() - INTERVAL 7 DAY) AS prev_visitors,
           uniqExactIf(session_id, timestamp >= now() - INTERVAL 7 DAY) AS cur_sessions,
           uniqExactIf(session_id, timestamp < now() - INTERVAL 7 DAY) AS prev_sessions
         FROM events
         WHERE site_id = #{site_p}
           AND timestamp >= now() - INTERVAL 14 DAY
           AND event_type = 'pageview'
           AND ip_is_bot = 0
         """) do
      {:ok, [r | _]} ->
        "Pageviews: #{r["cur_pv"]} (prev: #{r["prev_pv"]})\n" <>
          "Visitors: #{r["cur_visitors"]} (prev: #{r["prev_visitors"]})\n" <>
          "Sessions: #{r["cur_sessions"]} (prev: #{r["prev_sessions"]})"

      _ ->
        nil
    end
  end

  defp query_engagement(site_p) do
    case ClickHouse.query("""
         SELECT
           round(countIf(pv = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate,
           round(avg(dur), 0) AS avg_duration_s,
           round(avg(pv), 1) AS pages_per_session
         FROM (
           SELECT session_id,
             countIf(event_type = 'pageview') AS pv,
             maxIf(duration_s, event_type = 'duration' AND duration_s > 0) AS dur
           FROM events
           WHERE site_id = #{site_p}
             AND timestamp >= now() - INTERVAL 7 DAY
             AND ip_is_bot = 0
           GROUP BY session_id
           HAVING pv > 0
         )
         """) do
      {:ok, [r | _]} ->
        "Bounce Rate: #{r["bounce_rate"]}%\n" <>
          "Avg Session Duration: #{r["avg_duration_s"]}s\n" <>
          "Pages/Session: #{r["pages_per_session"]}"

      _ ->
        nil
    end
  end

  defp query_top_pages(site_p) do
    case ClickHouse.query("""
         SELECT url_path,
           countIf(event_type = 'pageview') AS pageviews,
           uniqExactIf(visitor_id, event_type = 'pageview') AS visitors
         FROM events
         WHERE site_id = #{site_p}
           AND timestamp >= now() - INTERVAL 7 DAY
           AND ip_is_bot = 0
           AND url_path != ''
         GROUP BY url_path
         ORDER BY pageviews DESC
         LIMIT 10
         """) do
      {:ok, rows} when rows != [] ->
        Enum.map_join(rows, "\n", fn r ->
          "- #{r["url_path"]}: #{r["pageviews"]} pageviews, #{r["visitors"]} visitors"
        end)

      _ ->
        nil
    end
  end

  defp query_top_sources(site_p) do
    case ClickHouse.query("""
         SELECT referrer_domain,
           countIf(event_type = 'pageview') AS pageviews,
           uniqExact(session_id) AS sessions
         FROM events
         WHERE site_id = #{site_p}
           AND timestamp >= now() - INTERVAL 7 DAY
           AND ip_is_bot = 0
           AND referrer_domain != ''
         GROUP BY referrer_domain
         ORDER BY pageviews DESC
         LIMIT 5
         """) do
      {:ok, rows} when rows != [] ->
        Enum.map_join(rows, "\n", fn r ->
          "- #{r["referrer_domain"]}: #{r["pageviews"]} pageviews, #{r["sessions"]} sessions"
        end)

      _ ->
        nil
    end
  end

  defp query_top_countries(site_p) do
    case ClickHouse.query("""
         SELECT ip_country,
           uniqExactIf(visitor_id, event_type = 'pageview') AS visitors,
           countIf(event_type = 'pageview') AS pageviews
         FROM events
         WHERE site_id = #{site_p}
           AND timestamp >= now() - INTERVAL 7 DAY
           AND ip_is_bot = 0
           AND ip_country != ''
         GROUP BY ip_country
         ORDER BY visitors DESC
         LIMIT 5
         """) do
      {:ok, rows} when rows != [] ->
        Enum.map_join(rows, "\n", fn r ->
          "- #{r["ip_country"]}: #{r["visitors"]} visitors, #{r["pageviews"]} pageviews"
        end)

      _ ->
        nil
    end
  end

  defp query_device_split(site_p) do
    case ClickHouse.query("""
         SELECT device_type,
           uniqExactIf(visitor_id, event_type = 'pageview') AS visitors
         FROM events
         WHERE site_id = #{site_p}
           AND timestamp >= now() - INTERVAL 7 DAY
           AND ip_is_bot = 0
           AND device_type != ''
         GROUP BY device_type
         ORDER BY visitors DESC
         """) do
      {:ok, rows} when rows != [] ->
        total = Enum.reduce(rows, 0, fn r, acc -> acc + to_num(r["visitors"]) end)

        Enum.map_join(rows, "\n", fn r ->
          v = to_num(r["visitors"])
          pct = if total > 0, do: Float.round(v / total * 100, 1), else: 0
          "- #{r["device_type"]}: #{v} visitors (#{pct}%)"
        end)

      _ ->
        nil
    end
  end

  defp query_gsc_summary(site_p) do
    case ClickHouse.query("""
         SELECT
           sum(clicks) AS clicks, sum(impressions) AS impressions,
           round(if(sum(impressions) > 0, sum(clicks) / sum(impressions) * 100, 0), 2) AS ctr,
           round(avg(position), 1) AS avg_pos,
           uniqExact(query) AS unique_queries
         FROM search_console FINAL
         WHERE site_id = #{site_p} AND date >= today() - 7
         """) do
      {:ok, [r | _]} ->
        if to_num(r["clicks"]) == 0 and to_num(r["impressions"]) == 0 do
          nil
        else
          "Clicks: #{r["clicks"]}, Impressions: #{r["impressions"]}, CTR: #{r["ctr"]}%, " <>
            "Avg Position: #{r["avg_pos"]}, Unique Queries: #{r["unique_queries"]}"
        end

      _ ->
        nil
    end
  end

  defp query_top_queries(site_p) do
    case ClickHouse.query("""
         SELECT query,
           sum(clicks) AS total_clicks,
           sum(impressions) AS total_impressions,
           round(avg(position), 1) AS avg_pos
         FROM search_console
         WHERE site_id = #{site_p} AND date >= today() - 7 AND query != ''
         GROUP BY query
         ORDER BY total_clicks DESC
         LIMIT 10
         """) do
      {:ok, rows} when rows != [] ->
        Enum.map_join(rows, "\n", fn r ->
          "- \"#{r["query"]}\": #{r["total_clicks"]} clicks, #{r["total_impressions"]} impressions, pos #{r["avg_pos"]}"
        end)

      _ ->
        nil
    end
  end

  defp query_new_keywords(site_p) do
    case ClickHouse.query("""
         SELECT query, sum(clicks) AS clicks, sum(impressions) AS impressions
         FROM search_console
         WHERE site_id = #{site_p} AND date >= today() - 7
           AND query NOT IN (
             SELECT query FROM search_console
             WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7
           )
         GROUP BY query
         HAVING impressions >= 3
         ORDER BY clicks DESC
         LIMIT 10
         """) do
      {:ok, rows} when rows != [] ->
        Enum.map_join(rows, "\n", fn r ->
          "- \"#{r["query"]}\": #{r["clicks"]} clicks, #{r["impressions"]} impressions"
        end)

      _ ->
        nil
    end
  end

  defp query_revenue_summary(site_p) do
    case ClickHouse.query("""
         SELECT
           sumIf(revenue, timestamp >= now() - INTERVAL 7 DAY) AS cur_rev,
           sumIf(revenue, timestamp < now() - INTERVAL 7 DAY) AS prev_rev,
           countIf(timestamp >= now() - INTERVAL 7 DAY) AS cur_orders,
           countIf(timestamp < now() - INTERVAL 7 DAY) AS prev_orders
         FROM ecommerce_events
         WHERE site_id = #{site_p}
           AND timestamp >= now() - INTERVAL 14 DAY
         """) do
      {:ok, [r | _]} ->
        cur = to_float(r["cur_rev"])
        prev = to_float(r["prev_rev"])

        if cur > 0 or prev > 0 do
          "Revenue: $#{Float.round(cur, 2)} (prev: $#{Float.round(prev, 2)})\n" <>
            "Orders: #{r["cur_orders"]} (prev: #{r["prev_orders"]})"
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp query_ad_spend_summary(site_p) do
    case ClickHouse.query("""
         SELECT
           platform,
           sumIf(spend, date >= today() - 7) AS cur_spend,
           sumIf(spend, date < today() - 7) AS prev_spend,
           sumIf(clicks, date >= today() - 7) AS cur_clicks
         FROM ad_spend FINAL
         WHERE site_id = #{site_p} AND date >= today() - 14
         GROUP BY platform
         HAVING cur_spend > 0 OR prev_spend > 0
         """) do
      {:ok, rows} when rows != [] ->
        Enum.map_join(rows, "\n", fn r ->
          "#{r["platform"]}: $#{r["cur_spend"]} spend (prev: $#{r["prev_spend"]}), #{r["cur_clicks"]} clicks"
        end)

      _ ->
        nil
    end
  end

  defp query_scraper_summary(site_p) do
    case ClickHouse.query("""
         SELECT
           count() AS total_visitors,
           sum(pv) AS total_pageviews
         FROM (
           SELECT visitor_id, countIf(event_type = 'pageview') AS pv
           FROM events
           WHERE site_id = #{site_p}
             AND timestamp >= now() - INTERVAL 7 DAY
             AND ip_is_bot = 1
           GROUP BY visitor_id
           HAVING pv >= 30
         )
         """) do
      {:ok, [r | _]} ->
        total = to_num(r["total_visitors"])

        if total > 0 do
          "#{total} high-volume bot visitors (30+ pageviews each), #{r["total_pageviews"]} total bot pageviews"
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp query_goal_performance(site, user) do
    goals = Goals.list_goals(site)
    if goals == [], do: nil, else: do_query_goal_performance(site, user, goals)
  rescue
    _ -> nil
  end

  defp do_query_goal_performance(site, user, _goals) do
    case Analytics.goal_completions(site, user, :week) do
      {:ok, results} when results != [] ->
        Enum.map_join(results, "\n", fn r ->
          "#{r.name} (#{r.goal_type}): #{r.completions} completions, #{r.unique_completers} unique, #{r.conversion_rate}% conv rate"
        end)

      _ ->
        nil
    end
  end

  defp query_funnel_analysis(site, user) do
    funnels = Goals.list_funnels(site)
    if funnels == [], do: nil, else: do_query_funnel_analysis(site, user, funnels)
  rescue
    _ -> nil
  end

  defp do_query_funnel_analysis(site, user, funnels) do
    results =
      funnels
      |> Enum.take(5)
      |> Enum.map(fn funnel ->
        case Analytics.funnel_stats(site, user, funnel, :month) do
          {:ok, [row | _]} ->
            steps = funnel.steps || []
            num_steps = length(steps)
            entered = to_num(row["step_1"] || 0)
            completed = to_num(row["step_#{num_steps}"] || 0)
            rate = if entered > 0, do: Float.round(completed / entered * 100, 1), else: 0.0

            biggest_drop =
              Enum.reduce(2..num_steps, {0, 0}, fn i, {worst_drop, worst_step} ->
                prev = to_num(row["step_#{i - 1}"] || 0)
                curr = to_num(row["step_#{i}"] || 0)
                drop = if prev > 0, do: prev - curr, else: 0
                if drop > worst_drop, do: {drop, i}, else: {worst_drop, worst_step}
              end)

            {worst_drop, worst_step} = biggest_drop
            step_name = Enum.at(steps, worst_step - 1)

            step_label =
              if step_name,
                do: step_name["value"] || "step #{worst_step}",
                else: "step #{worst_step}"

            "#{funnel.name}: #{entered} entered → #{completed} completed (#{rate}%). Biggest drop: #{worst_drop} at #{step_label}"

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if results == [], do: nil, else: Enum.join(results, "\n")
  end

  defp query_click_elements(site_p) do
    case ClickHouse.query("""
         SELECT
           JSONExtractString(properties, '_text') AS element_text,
           JSONExtractString(properties, '_tag') AS element_tag,
           count() AS clicks,
           uniq(visitor_id) AS visitors
         FROM events
         WHERE site_id = #{site_p}
           AND event_type = 'custom'
           AND event_name = '_click'
           AND ip_is_bot = 0
           AND timestamp >= now() - INTERVAL 7 DAY
         GROUP BY element_text, element_tag
         HAVING clicks >= 5
         ORDER BY clicks DESC
         LIMIT 10
         """) do
      {:ok, rows} when rows != [] ->
        Enum.map_join(rows, "\n", fn r ->
          "#{r["element_tag"]} \"#{r["element_text"]}\": #{r["clicks"]} clicks by #{r["visitors"]} visitors"
        end)

      _ ->
        nil
    end
  end

  defp query_suggested_paths(site, user) do
    case Analytics.suggested_funnels(site, user) do
      {:ok, rows} when rows != [] ->
        rows
        |> Enum.take(5)
        |> Enum.map_join("\n", fn r ->
          paths = r["path_sequence"] || []
          "#{Enum.join(paths, " → ")}: #{r["converters"]} converters"
        end)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp with_header(_title, nil), do: nil
  defp with_header(title, content), do: "## #{title}\n#{content}"
end
