defmodule Spectabas.Analytics.AnomalyDetector do
  @moduledoc """
  Detects significant changes in analytics metrics by comparing
  the current period to the previous equivalent period.

  Returns a list of anomaly maps with severity, metric, change, and message.
  """

  alias Spectabas.{ClickHouse, Accounts}
  alias Spectabas.Sites.Site
  alias Spectabas.Accounts.User
  import Spectabas.TypeHelpers, only: [to_int: 1, to_float: 1]

  @thresholds %{
    traffic_drop: -30,
    traffic_spike: 50,
    bounce_spike: 20,
    source_drop: -50,
    source_new: 5,
    exit_rate_spike: 30
  }

  @doc """
  Run anomaly detection for a site over the last 7 days vs the 7 days before.
  Returns {:ok, [anomaly]} or {:error, reason}.
  """
  def detect(%Site{} = site, %User{} = user) do
    with :ok <- authorize(site, user) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      current_from = DateTime.add(now, -7, :day)
      prev_from = DateTime.add(now, -14, :day)
      prev_to = DateTime.add(now, -7, :day)

      anomalies =
        []
        |> check_traffic(site, current_from, now, prev_from, prev_to)
        |> check_bounce_rate(site, current_from, now, prev_from, prev_to)
        |> check_sources(site, current_from, now, prev_from, prev_to)
        |> check_top_pages(site, current_from, now, prev_from, prev_to)
        |> check_exit_pages(site, current_from, now)
        |> check_entry_page_bounce(site, current_from, now, prev_from, prev_to)
        |> check_revenue(site, current_from, now, prev_from, prev_to)
        |> check_ad_traffic(site, current_from, now, prev_from, prev_to)
        |> check_ad_spend_roas(site)
        |> check_churn_risk(site)
        |> check_goal_conversion_drop(site, current_from, now, prev_from, prev_to)
        |> check_seo_rankings(site)
        |> check_seo_ctr_opportunities(site)
        |> check_seo_dropouts(site)
        |> check_seo_page_two(site)
        |> check_seo_landing_page_decline(site)
        |> check_seo_new_keywords(site)
        |> Enum.sort_by(& &1.severity_rank)

      {:ok, anomalies}
    end
  end

  # --- Traffic volume ---

  defp check_traffic(anomalies, site, cf, ct, pf, pt) do
    current = query_count(site, cf, ct)
    previous = query_count(site, pf, pt)

    if previous > 0 do
      pct = Float.round((current - previous) / previous * 100, 1)

      cond do
        pct <= @thresholds.traffic_drop ->
          [
            %{
              severity: :high,
              severity_rank: 1,
              category: "traffic",
              metric: "pageviews",
              current: current,
              previous: previous,
              change_pct: pct,
              message:
                "Traffic dropped #{abs(pct)}% this week (#{current} vs #{previous} pageviews)",
              action:
                "Check if a campaign ended, a backlink was removed, or there's a technical issue"
            }
            | anomalies
          ]

        pct >= @thresholds.traffic_spike ->
          [
            %{
              severity: :info,
              severity_rank: 3,
              category: "traffic",
              metric: "pageviews",
              current: current,
              previous: previous,
              change_pct: pct,
              message: "Traffic spiked #{pct}% this week (#{current} vs #{previous} pageviews)",
              action:
                "Investigate the source — a mention, campaign, or viral content may be driving it"
            }
            | anomalies
          ]

        true ->
          anomalies
      end
    else
      if current > 10 do
        [
          %{
            severity: :info,
            severity_rank: 3,
            category: "traffic",
            metric: "pageviews",
            current: current,
            previous: 0,
            change_pct: 100.0,
            message: "New traffic: #{current} pageviews this week (none last week)",
            action:
              "Your site is getting its first visitors — monitor sources to see where they're coming from"
          }
          | anomalies
        ]
      else
        anomalies
      end
    end
  end

  # --- Bounce rate ---

  defp check_bounce_rate(anomalies, site, cf, ct, pf, pt) do
    current_br = query_bounce_rate(site, cf, ct)
    previous_br = query_bounce_rate(site, pf, pt)

    diff = current_br - previous_br

    if previous_br > 0 and diff >= @thresholds.bounce_spike do
      [
        %{
          severity: :medium,
          severity_rank: 2,
          category: "engagement",
          metric: "bounce_rate",
          current: current_br,
          previous: previous_br,
          change_pct: Float.round(diff, 1),
          message:
            "Bounce rate increased from #{previous_br}% to #{current_br}% (+#{Float.round(diff, 1)} points)",
          action:
            "Check your top landing pages for broken content, slow loading, or poor mobile experience"
        }
        | anomalies
      ]
    else
      anomalies
    end
  end

  # --- Source changes ---

  defp check_sources(anomalies, site, cf, ct, pf, pt) do
    current_sources = query_sources(site, cf, ct)
    previous_sources = query_sources(site, pf, pt)

    prev_map =
      Map.new(previous_sources, fn s -> {s["referrer_domain"], to_int(s["visitors"])} end)

    curr_map = Map.new(current_sources, fn s -> {s["referrer_domain"], to_int(s["visitors"])} end)

    # Check for dropped sources
    dropped =
      Enum.reduce(prev_map, anomalies, fn {domain, prev_count}, acc ->
        curr_count = Map.get(curr_map, domain, 0)

        if prev_count >= 5 and curr_count == 0 do
          [
            %{
              severity: :medium,
              severity_rank: 2,
              category: "sources",
              metric: "referrer",
              current: curr_count,
              previous: prev_count,
              change_pct: -100.0,
              message:
                "Traffic from #{domain} disappeared (was #{prev_count} visitors last week)",
              action: "Check if a backlink was removed or a partnership ended"
            }
            | acc
          ]
        else
          if prev_count >= 10 do
            pct = (curr_count - prev_count) / prev_count * 100

            if pct <= @thresholds.source_drop do
              [
                %{
                  severity: :medium,
                  severity_rank: 2,
                  category: "sources",
                  metric: "referrer",
                  current: curr_count,
                  previous: prev_count,
                  change_pct: Float.round(pct, 1),
                  message:
                    "Traffic from #{domain} dropped #{abs(Float.round(pct, 1))}% (#{curr_count} vs #{prev_count})",
                  action:
                    "Investigate changes on #{domain} that might affect your referral traffic"
                }
                | acc
              ]
            else
              acc
            end
          else
            acc
          end
        end
      end)

    # Check for new sources
    Enum.reduce(curr_map, dropped, fn {domain, count}, acc ->
      if domain != "" and count >= @thresholds.source_new and not Map.has_key?(prev_map, domain) do
        [
          %{
            severity: :info,
            severity_rank: 3,
            category: "sources",
            metric: "referrer",
            current: count,
            previous: 0,
            change_pct: 100.0,
            message: "New traffic source: #{domain} sent #{count} visitors this week",
            action: "Investigate this source and consider building the relationship"
          }
          | acc
        ]
      else
        acc
      end
    end)
  end

  # --- Top pages changes ---

  defp check_top_pages(anomalies, site, cf, ct, pf, pt) do
    current_pages = query_top_pages(site, cf, ct)
    previous_pages = query_top_pages(site, pf, pt)

    prev_map = Map.new(previous_pages, fn p -> {p["url_path"], to_int(p["pageviews"])} end)

    Enum.reduce(current_pages, anomalies, fn page, acc ->
      path = page["url_path"]
      curr = to_int(page["pageviews"])
      prev = Map.get(prev_map, path, 0)

      if prev >= 10 do
        pct = (curr - prev) / prev * 100

        if pct <= -40 do
          [
            %{
              severity: :medium,
              severity_rank: 2,
              category: "pages",
              metric: "pageviews",
              current: curr,
              previous: prev,
              change_pct: Float.round(pct, 1),
              message: "#{path} dropped #{abs(Float.round(pct, 1))}% (#{curr} vs #{prev} views)",
              action:
                "Check if this page has broken links, was deindexed, or lost a referral source"
            }
            | acc
          ]
        else
          acc
        end
      else
        acc
      end
    end)
  end

  # --- High exit rate pages ---

  defp check_exit_pages(anomalies, site, cf, ct) do
    # True exit rate: % of sessions where this was the LAST page viewed
    sql = """
    SELECT
      last_page AS url_path,
      count() AS sessions,
      round(count() * 100.0 / greatest(total.total_sessions, 1), 1) AS exit_pct
    FROM (
      SELECT session_id, argMax(url_path, timestamp) AS last_page
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'pageview'
        AND ip_is_bot = 0
        AND timestamp >= #{ClickHouse.param(fmt(cf))}
        AND timestamp <= #{ClickHouse.param(fmt(ct))}
      GROUP BY session_id
    )
    CROSS JOIN (
      SELECT uniqExact(session_id) AS total_sessions
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'pageview'
        AND ip_is_bot = 0
        AND timestamp >= #{ClickHouse.param(fmt(cf))}
        AND timestamp <= #{ClickHouse.param(fmt(ct))}
    ) AS total
    GROUP BY last_page, total.total_sessions
    HAVING sessions >= 10
    ORDER BY sessions DESC
    LIMIT 5
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        # Only flag pages that are disproportionately high exit points
        # Skip homepages and known terminal pages
        skip_paths = ["/", "/dashboard", "/search"]

        Enum.reduce(rows, anomalies, fn row, acc ->
          path = row["url_path"]
          pct = to_float(row["exit_pct"])

          if path in skip_paths or
               String.contains?(path, "thank") or
               String.contains?(path, "confirm") or
               String.contains?(path, "success") or
               String.contains?(path, "logout") or
               pct < 5.0 do
            acc
          else
            [
              %{
                severity: :low,
                severity_rank: 4,
                category: "engagement",
                metric: "exit_rate",
                current: pct,
                previous: nil,
                change_pct: nil,
                message:
                  "#{path} is a top exit page (#{pct}% of sessions end here, #{row["sessions"]} sessions)",
                action: "Consider adding CTAs, related content, or reducing friction on this page"
              }
              | acc
            ]
          end
        end)

      _ ->
        anomalies
    end
  end

  # --- Revenue changes ---

  defp check_revenue(anomalies, site, cf, ct, pf, pt) do
    current_rev = query_revenue(site, cf, ct)
    previous_rev = query_revenue(site, pf, pt)

    if previous_rev > 0 do
      pct = Float.round((current_rev - previous_rev) / previous_rev * 100, 1)

      cond do
        pct <= -30 ->
          [
            %{
              severity: :high,
              severity_rank: 1,
              category: "revenue",
              metric: "revenue",
              current: current_rev,
              previous: previous_rev,
              change_pct: pct,
              message:
                "Revenue dropped #{abs(pct)}% this week ($#{Float.round(current_rev, 2)} vs $#{Float.round(previous_rev, 2)})",
              action:
                "Check if conversion paths are broken, pricing changed, or ad traffic quality declined"
            }
            | anomalies
          ]

        pct >= 50 ->
          [
            %{
              severity: :info,
              severity_rank: 3,
              category: "revenue",
              metric: "revenue",
              current: current_rev,
              previous: previous_rev,
              change_pct: pct,
              message:
                "Revenue up #{pct}% this week ($#{Float.round(current_rev, 2)} vs $#{Float.round(previous_rev, 2)})",
              action:
                "Investigate what's driving the growth — new campaign, seasonal trend, or product change"
            }
            | anomalies
          ]

        true ->
          anomalies
      end
    else
      if current_rev > 0 do
        [
          %{
            severity: :info,
            severity_rank: 3,
            category: "revenue",
            metric: "revenue",
            current: current_rev,
            previous: 0,
            change_pct: nil,
            message: "First revenue: $#{Float.round(current_rev, 2)} this week",
            action:
              "Your first ecommerce revenue is coming in — check Revenue Attribution to see which sources are converting"
          }
          | anomalies
        ]
      else
        anomalies
      end
    end
  end

  # --- Ad traffic insights ---

  defp check_ad_traffic(anomalies, site, cf, ct, pf, pt) do
    current_ads = query_ad_visitors(site, cf, ct)
    previous_ads = query_ad_visitors(site, pf, pt)

    curr_map = Map.new(current_ads, fn r -> {r["click_id_type"], to_int(r["visitors"])} end)
    prev_map = Map.new(previous_ads, fn r -> {r["click_id_type"], to_int(r["visitors"])} end)

    platform_labels = %{
      "google_ads" => "Google Ads",
      "bing_ads" => "Bing Ads",
      "meta_ads" => "Meta Ads"
    }

    # New platforms detected
    anomalies =
      Enum.reduce(curr_map, anomalies, fn {platform, count}, acc ->
        if count > 0 and not Map.has_key?(prev_map, platform) do
          label = platform_labels[platform] || platform

          [
            %{
              severity: :info,
              severity_rank: 3,
              category: "ad traffic",
              metric: "click_id",
              current: count,
              previous: 0,
              change_pct: nil,
              message: "New ad traffic: #{count} visitors from #{label} this week (via click ID)",
              action: "Check Visitor Quality and Time to Convert to evaluate this traffic source"
            }
            | acc
          ]
        else
          acc
        end
      end)

    # Significant ad traffic changes
    Enum.reduce(curr_map, anomalies, fn {platform, curr_count}, acc ->
      prev_count = Map.get(prev_map, platform, 0)

      if prev_count >= 10 do
        pct = Float.round((curr_count - prev_count) / prev_count * 100, 1)
        label = platform_labels[platform] || platform

        cond do
          pct <= -50 ->
            [
              %{
                severity: :medium,
                severity_rank: 2,
                category: "ad traffic",
                metric: "click_id",
                current: curr_count,
                previous: prev_count,
                change_pct: pct,
                message:
                  "#{label} traffic dropped #{abs(pct)}% (#{curr_count} vs #{prev_count} visitors)",
                action:
                  "Check if campaigns were paused, budgets reduced, or ad accounts have errors"
              }
              | acc
            ]

          pct >= 100 ->
            [
              %{
                severity: :info,
                severity_rank: 3,
                category: "ad traffic",
                metric: "click_id",
                current: curr_count,
                previous: prev_count,
                change_pct: pct,
                message:
                  "#{label} traffic surged #{pct}% (#{curr_count} vs #{prev_count} visitors)",
                action:
                  "Monitor Visitor Quality to ensure the increased traffic maintains engagement"
              }
              | acc
            ]

          true ->
            acc
        end
      else
        acc
      end
    end)
  end

  # --- Churn risk changes ---

  defp check_churn_risk(anomalies, site) do
    sql = """
    SELECT count() AS c
    FROM (
      SELECT visitor_id,
        countIf(timestamp >= now() - INTERVAL 14 DAY) AS recent,
        countIf(timestamp >= now() - INTERVAL 28 DAY AND timestamp < now() - INTERVAL 14 DAY) AS prior
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'pageview' AND ip_is_bot = 0
        AND timestamp >= now() - INTERVAL 28 DAY
        AND visitor_id IN (
          SELECT DISTINCT visitor_id FROM ecommerce_events
          WHERE site_id = #{ClickHouse.param(site.id)}
            #{Spectabas.Analytics.ecommerce_source_filter(site)}
        )
      GROUP BY visitor_id
      HAVING prior >= 3 AND recent <= prior / 2
    )
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"c" => c}]} ->
        count = to_int(c)

        if count >= 3 do
          [
            %{
              severity: :medium,
              severity_rank: 2,
              category: "retention",
              metric: "churn_risk",
              current: count,
              previous: nil,
              change_pct: nil,
              message: "#{count} customers flagged as churn risk (50%+ session decline)",
              action:
                "Visit Churn Risk page to see affected customers and trigger re-engagement outreach"
            }
            | anomalies
          ]
        else
          anomalies
        end

      _ ->
        anomalies
    end
  end

  # --- Query helpers ---

  defp query_count(site, from, to) do
    sql = """
    SELECT countIf(event_type = 'pageview') AS c
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= #{ClickHouse.param(fmt(from))}
      AND timestamp <= #{ClickHouse.param(fmt(to))}
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"c" => c}]} -> to_int(c)
      _ -> 0
    end
  end

  defp query_bounce_rate(site, from, to) do
    sql = """
    SELECT round(countIf(pv = 1 AND dur = 0) / greatest(count(), 1) * 100, 1) AS br
    FROM (
      SELECT session_id, countIf(event_type = 'pageview') AS pv,
        maxIf(duration_s, event_type = 'duration') AS dur
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(fmt(from))}
        AND timestamp <= #{ClickHouse.param(fmt(to))}
      GROUP BY session_id
    )
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"br" => br}]} -> to_float(br)
      _ -> 0.0
    end
  end

  defp query_sources(site, from, to) do
    sql = """
    SELECT referrer_domain, uniq(visitor_id) AS visitors
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= #{ClickHouse.param(fmt(from))}
      AND timestamp <= #{ClickHouse.param(fmt(to))}
      AND referrer_domain != ''
    GROUP BY referrer_domain
    ORDER BY visitors DESC
    LIMIT 20
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_top_pages(site, from, to) do
    sql = """
    SELECT url_path, count() AS pageviews
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND event_type = 'pageview'
      AND timestamp >= #{ClickHouse.param(fmt(from))}
      AND timestamp <= #{ClickHouse.param(fmt(to))}
    GROUP BY url_path
    ORDER BY pageviews DESC
    LIMIT 20
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp query_revenue(site, from, to) do
    sql = """
    SELECT sum(revenue) AS r
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site.id)}
      #{Spectabas.Analytics.ecommerce_source_filter(site)}
      AND timestamp >= #{ClickHouse.param(fmt(from))}
      AND timestamp <= #{ClickHouse.param(fmt(to))}
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"r" => r}]} -> to_float(r)
      _ -> 0.0
    end
  end

  defp query_ad_visitors(site, from, to) do
    sql = """
    SELECT click_id_type, uniq(visitor_id) AS visitors
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND click_id != '' AND click_id_type != ''
      AND event_type = 'pageview' AND ip_is_bot = 0
      AND timestamp >= #{ClickHouse.param(fmt(from))}
      AND timestamp <= #{ClickHouse.param(fmt(to))}
    GROUP BY click_id_type
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp authorize(site, user) do
    if Accounts.can_access_site?(user, site), do: :ok, else: {:error, :unauthorized}
  end

  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  # --- SEO ranking changes (from search_console) ---

  defp check_seo_rankings(anomalies, site) do
    site_p = ClickHouse.param(site.id)

    # Keywords that improved into top 10 (were >10, now <=10)
    case ClickHouse.query("""
         SELECT cur.query, cur.pos AS current_pos, prev.pos AS previous_pos,
           cur.clicks AS clicks
         FROM (
           SELECT query, round(avg(position), 1) AS pos, sum(clicks) AS clicks
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 7
           GROUP BY query HAVING sum(impressions) >= 5
         ) cur
         JOIN (
           SELECT query, round(avg(position), 1) AS pos
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7
           GROUP BY query HAVING sum(impressions) >= 5
         ) prev ON cur.query = prev.query
         WHERE prev.pos > 10 AND cur.pos <= 10
         ORDER BY cur.clicks DESC
         LIMIT 5
         """) do
      {:ok, rows} when rows != [] ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          [
            %{
              severity: :info,
              severity_rank: 4,
              category: "seo",
              metric: "ranking_improvement",
              current: to_float(row["current_pos"]),
              previous: to_float(row["previous_pos"]),
              change_pct: nil,
              message:
                "\"#{row["query"]}\" moved into top 10 (#{row["previous_pos"]} → #{row["current_pos"]})",
              action:
                "This keyword is now on page 1. Optimize the landing page to capture more clicks."
            }
            | acc
          ]
        end)

      _ ->
        anomalies
    end
  end

  # --- SEO CTR opportunities ---

  defp check_seo_ctr_opportunities(anomalies, site) do
    site_p = ClickHouse.param(site.id)

    case ClickHouse.query("""
         SELECT query, sum(impressions) AS impr, sum(clicks) AS clicks,
           if(sum(impressions) > 0, round(sum(clicks) / sum(impressions) * 100, 2), 0) AS ctr,
           round(avg(position), 1) AS pos
         FROM search_console FINAL
         WHERE site_id = #{site_p} AND date >= today() - 7
         GROUP BY query
         HAVING impr >= 100 AND ctr < 2 AND pos <= 10
         ORDER BY impr DESC
         LIMIT 3
         """) do
      {:ok, rows} when rows != [] ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          [
            %{
              severity: :medium,
              severity_rank: 2,
              category: "seo",
              metric: "ctr_opportunity",
              current: to_float(row["ctr"]),
              previous: nil,
              change_pct: nil,
              message:
                "\"#{row["query"]}\" has #{format_num(to_int(row["impr"]))} impressions but only #{row["ctr"]}% CTR (position #{row["pos"]})",
              action:
                "Improve the page title and meta description for this keyword to increase click-through rate."
            }
            | acc
          ]
        end)

      _ ->
        anomalies
    end
  end

  # --- Ad spend ROAS changes ---

  defp check_ad_spend_roas(anomalies, site) do
    site_p = ClickHouse.param(site.id)

    # Check if site has ad spend data
    case ClickHouse.query("""
         SELECT
           sum(if(date >= today() - 7, spend, 0)) AS current_spend,
           sum(if(date < today() - 7, spend, 0)) AS prev_spend
         FROM ad_spend FINAL
         WHERE site_id = #{site_p} AND date >= today() - 14
         """) do
      {:ok, [%{"current_spend" => cs, "prev_spend" => ps}]}
      when is_number(cs) and cs > 0 and is_number(ps) and ps > 0 ->
        change = Float.round((cs - ps) / ps * 100, 1)

        if abs(change) >= 30 do
          [
            %{
              severity: if(change > 0, do: :info, else: :medium),
              severity_rank: if(change > 0, do: 4, else: 2),
              category: "advertising",
              metric: "ad_spend_change",
              current: cs,
              previous: ps,
              change_pct: change,
              message:
                "Ad spend #{if change > 0, do: "increased", else: "decreased"} by #{abs(change)}% this week ($#{Float.round(cs, 0)} vs $#{Float.round(ps, 0)})",
              action:
                if(change > 0,
                  do:
                    "Review campaign performance to ensure increased spend is generating proportional returns.",
                  else:
                    "Check if campaigns were paused or budgets reduced — this may impact traffic."
                )
            }
            | anomalies
          ]
        else
          anomalies
        end

      _ ->
        anomalies
    end
  end

  defp format_num(n) when is_integer(n) and n >= 1000 do
    "#{div(n, 1000)}k"
  end

  defp format_num(n), do: to_string(n)

  # --- SEO: keywords falling out of top 10 ---

  defp check_seo_dropouts(anomalies, site) do
    site_p = ClickHouse.param(site.id)

    case ClickHouse.query("""
         SELECT cur.query AS query, cur.pos AS current_pos, prev.pos AS previous_pos,
           prev.clicks AS lost_clicks
         FROM (
           SELECT query, round(avg(position), 1) AS pos, sum(clicks) AS clicks
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 7
           GROUP BY query HAVING sum(impressions) >= 5
         ) cur
         JOIN (
           SELECT query, round(avg(position), 1) AS pos, sum(clicks) AS clicks
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7
           GROUP BY query HAVING sum(impressions) >= 5
         ) prev ON cur.query = prev.query
         WHERE prev.pos <= 10 AND cur.pos > 10
         ORDER BY prev.clicks DESC
         LIMIT 5
         SETTINGS max_execution_time = 15
         """) do
      {:ok, rows} when rows != [] ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          [
            %{
              severity: :medium,
              severity_rank: 2,
              category: "seo",
              metric: "ranking_dropout",
              current: to_float(row["current_pos"]),
              previous: to_float(row["previous_pos"]),
              change_pct: nil,
              message:
                "\"#{row["query"]}\" dropped out of the top 10 (#{row["previous_pos"]} → #{row["current_pos"]})",
              action:
                "Review the landing page — content freshness, internal links, or competitor changes are likely causes. You may have lost ~#{row["lost_clicks"]} weekly clicks."
            }
            | acc
          ]
        end)

      _ ->
        anomalies
    end
  end

  # --- SEO: page-2 keywords (positions 11-20) with decent impression volume ---

  defp check_seo_page_two(anomalies, site) do
    site_p = ClickHouse.param(site.id)

    case ClickHouse.query("""
         SELECT query, sum(impressions) AS impr, sum(clicks) AS clicks,
           round(avg(position), 1) AS pos
         FROM search_console FINAL
         WHERE site_id = #{site_p} AND date >= today() - 7
         GROUP BY query
         HAVING impr >= 100 AND pos > 10 AND pos <= 20
         ORDER BY impr DESC
         LIMIT 5
         SETTINGS max_execution_time = 15
         """) do
      {:ok, rows} when rows != [] ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          [
            %{
              severity: :low,
              severity_rank: 4,
              category: "seo",
              metric: "page_two_opportunity",
              current: to_float(row["pos"]),
              previous: nil,
              change_pct: nil,
              message:
                "\"#{row["query"]}\" is on page 2 (position #{row["pos"]}) with #{format_num(to_int(row["impr"]))} impressions",
              action:
                "Build internal links and refresh content for this keyword — moving from page 2 to page 1 typically 5x's clicks."
            }
            | acc
          ]
        end)

      _ ->
        anomalies
    end
  end

  # --- SEO: top organic landing pages losing GSC clicks WoW ---

  defp check_seo_landing_page_decline(anomalies, site) do
    site_p = ClickHouse.param(site.id)

    case ClickHouse.query("""
         SELECT cur.page AS page, cur.clicks AS current_clicks, prev.clicks AS previous_clicks
         FROM (
           SELECT page, sum(clicks) AS clicks
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 7
           GROUP BY page
         ) cur
         JOIN (
           SELECT page, sum(clicks) AS clicks
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 14 AND date < today() - 7
           GROUP BY page
         ) prev ON cur.page = prev.page
         WHERE prev.clicks >= 20 AND cur.clicks <= prev.clicks * 0.7
         ORDER BY (prev.clicks - cur.clicks) DESC
         LIMIT 5
         SETTINGS max_execution_time = 15
         """) do
      {:ok, rows} when rows != [] ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          curr = to_int(row["current_clicks"])
          prev = to_int(row["previous_clicks"])
          pct = if prev > 0, do: Float.round((curr - prev) / prev * 100, 1), else: 0.0

          [
            %{
              severity: :medium,
              severity_rank: 2,
              category: "seo",
              metric: "landing_page_clicks",
              current: curr,
              previous: prev,
              change_pct: pct,
              message:
                "Organic clicks to #{row["page"]} dropped #{abs(pct)}% (#{curr} vs #{prev})",
              action:
                "Check the page in Search Console — likely ranking loss for its top keywords. Refresh content or audit recent changes."
            }
            | acc
          ]
        end)

      _ ->
        anomalies
    end
  end

  # --- SEO: keywords with first impressions this week ---

  defp check_seo_new_keywords(anomalies, site) do
    site_p = ClickHouse.param(site.id)

    case ClickHouse.query("""
         SELECT cur.query AS query, cur.impr AS impressions, cur.pos AS position
         FROM (
           SELECT query, sum(impressions) AS impr, round(avg(position), 1) AS pos
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 7
           GROUP BY query HAVING impr >= 20
         ) cur
         LEFT JOIN (
           SELECT DISTINCT query
           FROM search_console FINAL
           WHERE site_id = #{site_p} AND date >= today() - 60 AND date < today() - 7
         ) prev ON cur.query = prev.query
         WHERE prev.query = ''
         ORDER BY cur.impr DESC
         LIMIT 5
         SETTINGS max_execution_time = 15
         """) do
      {:ok, rows} when rows != [] ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          [
            %{
              severity: :info,
              severity_rank: 3,
              category: "seo",
              metric: "new_keyword",
              current: to_float(row["position"]),
              previous: nil,
              change_pct: nil,
              message:
                "New ranking: \"#{row["query"]}\" (position #{row["position"]}, #{format_num(to_int(row["impressions"]))} impressions)",
              action:
                "A keyword you haven't ranked for in 60 days now appears. Decide whether to optimize the page further to push for top results."
            }
            | acc
          ]
        end)

      _ ->
        anomalies
    end
  end

  # --- Top entry page with bounce rate spike ---

  defp check_entry_page_bounce(anomalies, site, cf, ct, pf, pt) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT cur.entry_page AS page, cur.sessions AS sessions,
           cur.bounce_rate AS current_br, prev.bounce_rate AS previous_br
    FROM (
      SELECT entry_page,
             count() AS sessions,
             round(countIf(is_bounce = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate
      FROM daily_session_facts
      WHERE site_id = #{site_p}
        AND date >= toDate(#{ClickHouse.param(fmt(cf))})
        AND date <= toDate(#{ClickHouse.param(fmt(ct))})
      GROUP BY entry_page HAVING sessions >= 30
    ) cur
    JOIN (
      SELECT entry_page,
             round(countIf(is_bounce = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate
      FROM daily_session_facts
      WHERE site_id = #{site_p}
        AND date >= toDate(#{ClickHouse.param(fmt(pf))})
        AND date <= toDate(#{ClickHouse.param(fmt(pt))})
      GROUP BY entry_page HAVING count() >= 30
    ) prev ON cur.entry_page = prev.entry_page
    WHERE cur.bounce_rate - prev.bounce_rate >= 20
    ORDER BY cur.sessions DESC
    LIMIT 3
    SETTINGS max_execution_time = 15
    """

    case ClickHouse.query(sql) do
      {:ok, rows} when rows != [] ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          curr = to_float(row["current_br"])
          prev = to_float(row["previous_br"])

          [
            %{
              severity: :medium,
              severity_rank: 2,
              category: "engagement",
              metric: "entry_page_bounce",
              current: curr,
              previous: prev,
              change_pct: Float.round(curr - prev, 1),
              message:
                "#{row["page"]} bounce rate jumped #{prev}% → #{curr}% (#{row["sessions"]} sessions)",
              action:
                "This is a high-volume entry page that's losing visitors fast. Check for recent layout changes, broken hero/CTA, slow load, or paid traffic mismatch."
            }
            | acc
          ]
        end)

      _ ->
        anomalies
    end
  end

  # --- Goal conversion-rate drop (uses Postgres goals + ClickHouse events) ---
  #
  # Single scan of the 14-day events window with one uniqIf-per-goal in the
  # SELECT list. Replaces the original "one scan per goal" approach which was
  # the dominant cost of the daily anomaly worker (per CLAUDE.md feedback,
  # rolled out in v6.9.21 after spiking ClickHouse CPU on v6.9.20).
  defp check_goal_conversion_drop(anomalies, site, cf, ct, pf, pt) do
    goals =
      site
      |> Spectabas.Goals.list_goals()
      # Cap to keep the SQL bounded — 20 goals already gives 42 uniqIf
      # aggregates in one SELECT, plenty without making CH parse a megabyte.
      |> Enum.take(20)
      |> Enum.map(fn g -> {g, goal_condition_for_anomaly(g)} end)
      |> Enum.reject(fn {_g, cond_sql} -> is_nil(cond_sql) end)

    if goals == [] do
      anomalies
    else
      site_p = ClickHouse.param(site.id)
      cf_p = ClickHouse.param(fmt(cf))
      ct_p = ClickHouse.param(fmt(ct))
      pf_p = ClickHouse.param(fmt(pf))
      pt_p = ClickHouse.param(fmt(pt))

      goal_selects =
        goals
        |> Enum.with_index()
        |> Enum.flat_map(fn {{_g, cond_sql}, idx} ->
          [
            "uniqIf(visitor_id, #{cond_sql} AND timestamp >= #{cf_p} AND timestamp <= #{ct_p}) AS g#{idx}_cur",
            "uniqIf(visitor_id, #{cond_sql} AND timestamp >= #{pf_p} AND timestamp <= #{pt_p}) AS g#{idx}_prev"
          ]
        end)
        |> Enum.join(",\n  ")

      sql = """
      SELECT
        #{goal_selects},
        uniqIf(visitor_id, event_type = 'pageview' AND timestamp >= #{cf_p} AND timestamp <= #{ct_p}) AS cur_total,
        uniqIf(visitor_id, event_type = 'pageview' AND timestamp >= #{pf_p} AND timestamp <= #{pt_p}) AS prev_total
      FROM events
      WHERE site_id = #{site_p}
        AND ip_is_bot = 0
        AND event_type IN ('pageview', 'custom')
        AND timestamp >= #{pf_p}
        AND timestamp <= #{ct_p}
      SETTINGS max_execution_time = 30
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} ->
          cur_t = to_int(row["cur_total"])
          prev_t = to_int(row["prev_total"])

          # Baseline activity check applies once for the whole site, not per goal.
          if prev_t >= 50 and cur_t >= 50 do
            goals
            |> Enum.with_index()
            |> Enum.reduce(anomalies, fn {{goal, _cond}, idx}, acc ->
              evaluate_goal_drop(acc, goal, idx, row, cur_t, prev_t)
            end)
          else
            anomalies
          end

        _ ->
          anomalies
      end
    end
  rescue
    _ -> anomalies
  end

  defp evaluate_goal_drop(anomalies, goal, idx, row, cur_t, prev_t) do
    cur_c = to_int(row["g#{idx}_cur"])
    prev_c = to_int(row["g#{idx}_prev"])

    cur_rate = if cur_t > 0, do: cur_c / cur_t * 100, else: 0.0
    prev_rate = if prev_t > 0, do: prev_c / prev_t * 100, else: 0.0

    if prev_rate >= 0.5 and prev_rate - cur_rate >= 1.0 do
      drop_pct =
        if prev_rate > 0,
          do: Float.round((cur_rate - prev_rate) / prev_rate * 100, 1),
          else: 0.0

      [
        %{
          severity: :medium,
          severity_rank: 2,
          category: "revenue",
          metric: "goal_conversion",
          current: Float.round(cur_rate, 2),
          previous: Float.round(prev_rate, 2),
          change_pct: drop_pct,
          message:
            "\"#{goal.name}\" conversion rate dropped #{Float.round(prev_rate, 2)}% → #{Float.round(cur_rate, 2)}%",
          action:
            "Audit the conversion path for this goal — entry pages, form behavior, CTAs, and any recent UI/copy changes."
        }
        | anomalies
      ]
    else
      anomalies
    end
  end

  # Goal-condition SQL — mirrors Spectabas.Analytics.goal_condition/1 (which is
  # private). Kept here to avoid widening the API surface of Analytics. Returns
  # nil for unknown / invalid goals so the caller can skip them.
  defp goal_condition_for_anomaly(goal) do
    case goal.goal_type do
      "pageview" ->
        path = goal.page_path |> to_string() |> String.replace("*", "%")
        "(event_type = 'pageview' AND url_path LIKE #{ClickHouse.param(path)})"

      "custom_event" ->
        "(event_type = 'custom' AND event_name = #{ClickHouse.param(to_string(goal.event_name))})"

      "click_element" ->
        case to_string(goal.element_selector || "") do
          "#" <> id ->
            "(event_type = 'custom' AND event_name = '_click' AND JSONExtractString(properties, '_id') = #{ClickHouse.param(id)})"

          "text:" <> text ->
            "(event_type = 'custom' AND event_name = '_click' AND JSONExtractString(properties, '_text') = #{ClickHouse.param(text)})"

          _ ->
            nil
        end

      _ ->
        nil
    end
  end
end
