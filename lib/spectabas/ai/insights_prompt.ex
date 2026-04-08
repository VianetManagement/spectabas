defmodule Spectabas.AI.InsightsPrompt do
  @moduledoc """
  Builds the prompt for AI-powered weekly insights analysis.
  Gathers aggregated metrics from all data sources and formats them
  for the AI provider. Never sends raw visitor data — only aggregates.
  """

  alias Spectabas.ClickHouse
  alias Spectabas.Analytics.AnomalyDetector
  import Spectabas.TypeHelpers, only: [to_num: 1, to_float: 1]

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
  Notable patterns in visitor behavior.

  ## Revenue & Advertising
  Revenue trends and ad performance observations (only if data exists).

  Keep it concise — under 500 words total. Use specific numbers from the data.
  If a section has no relevant data, skip it entirely.
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
        with_header("Traffic Summary (last 7 days)", query_traffic_summary(site_p)),
        with_header("Search Console Data (last 7 days)", query_gsc_summary(site_p)),
        with_header("Revenue (last 7 days)", query_revenue_summary(site_p)),
        with_header("Ad Spend (last 7 days)", query_ad_spend_summary(site_p))
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
          base =
            "Clicks: #{r["clicks"]}, Impressions: #{r["impressions"]}, CTR: #{r["ctr"]}%, Avg Position: #{r["avg_pos"]}, Queries: #{r["unique_queries"]}"

          # Top ranking changes
          changes =
            case ClickHouse.query("""
                 SELECT cur.query, round(prev.pos - cur.pos, 1) AS change, cur.pos AS current_pos
                 FROM (
                   SELECT query, avg(position) AS pos FROM search_console FINAL
                   WHERE site_id = #{site_p} AND date >= today() - 7
                   GROUP BY query HAVING sum(impressions) >= 5
                 ) cur
                 JOIN (
                   SELECT query, avg(position) AS pos FROM search_console FINAL
                   WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7
                   GROUP BY query HAVING sum(impressions) >= 5
                 ) prev ON cur.query = prev.query
                 ORDER BY abs(prev.pos - cur.pos) DESC
                 LIMIT 5
                 """) do
              {:ok, rows} when rows != [] ->
                "\nBiggest ranking changes:\n" <>
                  Enum.map_join(rows, "\n", fn r ->
                    dir = if to_float(r["change"]) > 0, do: "improved", else: "dropped"

                    "- \"#{r["query"]}\" #{dir} by #{abs(to_float(r["change"]))} positions (now #{r["current_pos"]})"
                  end)

              _ ->
                ""
            end

          base <> changes
        end

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

  defp with_header(_title, nil), do: nil
  defp with_header(title, content), do: "## #{title}\n#{content}"
end
