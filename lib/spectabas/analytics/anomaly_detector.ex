defmodule Spectabas.Analytics.AnomalyDetector do
  @moduledoc """
  Detects significant changes in analytics metrics by comparing
  the current period to the previous equivalent period.

  Returns a list of anomaly maps with severity, metric, change, and message.
  """

  alias Spectabas.{ClickHouse, Accounts}
  alias Spectabas.Sites.Site
  alias Spectabas.Accounts.User

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
        |> check_revenue(site, current_from, now, prev_from, prev_to)
        |> check_ad_traffic(site, current_from, now, prev_from, prev_to)
        |> check_churn_risk(site)
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
    sql = """
    SELECT
      url_path,
      count() AS views,
      countIf(is_bounce = 1) AS bounces,
      round(countIf(is_bounce = 1) / greatest(count(), 1) * 100, 1) AS exit_rate
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND event_type = 'pageview'
      AND timestamp >= #{ClickHouse.param(fmt(cf))}
      AND timestamp <= #{ClickHouse.param(fmt(ct))}
    GROUP BY url_path
    HAVING views >= 20 AND exit_rate >= 85
    ORDER BY views DESC
    LIMIT 3
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.reduce(rows, anomalies, fn row, acc ->
          path = row["url_path"]
          rate = to_float(row["exit_rate"])

          # Skip known terminal pages
          if String.contains?(path, "thank") or String.contains?(path, "confirm") or
               String.contains?(path, "success") do
            acc
          else
            [
              %{
                severity: :low,
                severity_rank: 4,
                category: "engagement",
                metric: "exit_rate",
                current: rate,
                previous: nil,
                change_pct: nil,
                message: "#{path} has a #{rate}% exit rate (#{row["views"]} views)",
                action: "Visitors leave from this page — add internal links or a call to action"
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

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
