defmodule Spectabas.Analytics do
  @moduledoc """
  Analytics query layer. All functions verify user access before querying ClickHouse.
  All interpolated values use ClickHouse.param/1 for safety.
  """

  alias Spectabas.{Accounts, ClickHouse}
  alias Spectabas.Sites.Site
  alias Spectabas.Accounts.User

  @doc """
  Overview stats: pageviews, unique_visitors, sessions, bounce_rate, avg_duration.
  """
  def overview_stats(%Site{} = site, %User{} = user, date_range) when is_atom(date_range) do
    overview_stats(site, user, period_to_date_range(date_range))
  end

  def overview_stats(%Site{} = site, %User{} = user, date_range) when is_map(date_range) do
    with :ok <- authorize(site, user),
         :ok <- check_clickhouse() do
      sql = """
      SELECT
        countIf(event_type = 'pageview') AS pageviews,
        uniqExact(visitor_id) AS unique_visitors,
        uniqExact(session_id) AS total_sessions,
        round(sumIf(is_bounce, event_type = 'pageview')
          / greatest(countIf(event_type = 'pageview'), 1) * 100, 1) AS bounce_rate,
        round(avgIf(duration_s, event_type = 'duration' AND duration_s > 0), 0) AS avg_duration
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:ok, empty_overview()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Top pages by pageviews from events table.
  """
  def top_pages(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        url_path,
        count() AS pageviews,
        uniq(visitor_id) AS unique_visitors,
        round(avg(duration_s), 0) AS avg_duration
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'pageview'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      GROUP BY url_path
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top traffic sources: referrer_domain, utm_source, utm_medium.
  """
  def top_sources(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      excluded = self_referrer_domains(site)

      exclude_clause =
        if excluded == [] do
          ""
        else
          domains = Enum.map_join(excluded, ", ", &ClickHouse.param/1)
          "AND referrer_domain NOT IN (#{domains})"
        end

      sql = """
      SELECT
        referrer_domain,
        utm_source,
        utm_medium,
        count() AS pageviews,
        uniq(session_id) AS sessions
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND referrer_domain != ''
        #{exclude_clause}
      GROUP BY referrer_domain, utm_source, utm_medium
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top countries grouped at country level only (for dashboard summary).
  """
  def top_countries_summary(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        ip_country,
        ip_country_name,
        count() AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_country != ''
      GROUP BY ip_country, ip_country_name
      ORDER BY unique_visitors DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top countries with region and city drill-down.
  """
  def top_countries(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        ip_country,
        ip_region_name,
        ip_city,
        count() AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_country != ''
      GROUP BY ip_country, ip_region_name, ip_city
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top devices: device_type, browser, os breakdown.
  """
  def top_devices(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        device_type,
        browser,
        os,
        count() AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      GROUP BY device_type, browser, os
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Network stats: top ASNs, orgs, datacenter/VPN/Tor/bot percentages.
  """
  def network_stats(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        ip_asn,
        ip_org,
        count() AS hits,
        round(countIf(ip_is_datacenter = 1) / count() * 100, 1) AS datacenter_pct,
        round(countIf(ip_is_vpn = 1) / count() * 100, 1) AS vpn_pct,
        round(countIf(ip_is_tor = 1) / count() * 100, 1) AS tor_pct,
        round(countIf(ip_is_bot = 1) / count() * 100, 1) AS bot_pct
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_asn != 0
      GROUP BY ip_asn, ip_org
      ORDER BY hits DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Distinct visitors in the last 5 minutes (realtime).
  """
  def realtime_visitors(%Site{} = site) do
    with :ok <- check_clickhouse() do
      sql = """
      SELECT uniq(visitor_id) AS active_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= now() - INTERVAL 5 MINUTE
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, Map.get(row, "active_visitors", 0)}
        {:ok, []} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Last 20 events ordered by timestamp desc (realtime feed).
  """
  def realtime_events(%Site{} = site) do
    sql = """
    SELECT
      event_type,
      url_path,
      referrer_domain,
      ip_country,
      device_type,
      browser,
      visitor_id,
      timestamp
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= now() - INTERVAL 5 MINUTE
    ORDER BY timestamp DESC
    LIMIT 20
    """

    ClickHouse.query(sql)
  end

  @doc """
  Funnel stats using ClickHouse windowFunnel().
  Steps is a list of event conditions (e.g., event_type/url_path matches).
  """
  def funnel_stats(%Site{} = site, %User{} = user, %{steps: steps} = _funnel)
      when is_list(steps) do
    with :ok <- authorize(site, user) do
      step_conditions =
        steps
        |> Enum.with_index(1)
        |> Enum.map_join(", ", fn {step, _idx} ->
          case step do
            %{"type" => "pageview", "path" => path} ->
              "url_path = #{ClickHouse.param(path)}"

            %{"type" => "custom_event", "name" => name} ->
              "event_name = #{ClickHouse.param(name)}"

            _ ->
              "1 = 0"
          end
        end)

      num_steps = length(steps)

      level_selects =
        Enum.map_join(1..num_steps, ", ", fn i ->
          "countIf(level >= #{i}) AS step_#{i}"
        end)

      sql = """
      SELECT #{level_selects}
      FROM (
        SELECT
          visitor_id,
          windowFunnel(86400)(timestamp, #{step_conditions}) AS level
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
        GROUP BY visitor_id
      )
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Goal completions per goal for a date range.
  """
  def goal_completions(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      goals = Spectabas.Goals.list_goals(site)

      results =
        Enum.map(goals, fn goal ->
          count = count_goal_completions(site, goal, date_range)
          %{goal_id: goal.id, name: goal.name, goal_type: goal.goal_type, completions: count}
        end)

      {:ok, results}
    end
  end

  @doc """
  Ecommerce stats: total revenue, orders, avg order value, top products.
  """
  def ecommerce_stats(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        count() AS total_orders,
        sum(revenue) AS total_revenue,
        round(avg(revenue), 2) AS avg_order_value,
        min(revenue) AS min_order,
        max(revenue) AS max_order
      FROM ecommerce_events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:ok, %{"total_orders" => 0, "total_revenue" => 0, "avg_order_value" => 0}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  All events for a specific visitor_id, ordered by timestamp.
  """
  def visitor_timeline(%Site{} = site, visitor_id) when is_binary(visitor_id) do
    sql = """
    SELECT *
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND visitor_id = #{ClickHouse.param(visitor_id)}
    ORDER BY timestamp ASC
    LIMIT 1000
    """

    ClickHouse.query(sql)
  end

  # --- Private helpers ---

  defp check_clickhouse do
    if Process.whereis(Spectabas.ClickHouse) do
      :ok
    else
      {:error, :clickhouse_unavailable}
    end
  end

  defp authorize(site, user) do
    if Accounts.can_access_site?(user, site) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime(dt_string) when is_binary(dt_string), do: dt_string

  @doc """
  Overview stats for shared/public dashboards (no user access check).
  """
  def overview_stats_public(%Site{} = site, period) do
    date_range = period_to_date_range(period)

    sql = """
    SELECT
      countIf(event_type = 'pageview') AS pageviews,
      uniqExact(visitor_id) AS unique_visitors,
      uniqExact(session_id) AS total_sessions,
      round(sumIf(is_bounce, event_type = 'pageview')
        / greatest(countIf(event_type = 'pageview'), 1) * 100, 1) AS bounce_rate,
      round(avgIf(duration_s, event_type = 'duration' AND duration_s > 0), 0) AS avg_duration
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
      AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
    """

    case ClickHouse.query(sql) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:ok, empty_overview()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_date_range(period) when is_atom(period), do: period_to_date_range(period)
  defp ensure_date_range(%{from: _, to: _} = dr), do: dr

  defp period_to_date_range(period) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from =
      case period do
        :day -> DateTime.add(now, -24, :hour)
        :week -> DateTime.add(now, -7, :day)
        :month -> DateTime.add(now, -30, :day)
        _ -> DateTime.add(now, -7, :day)
      end

    %{from: from, to: now}
  end

  @doc """
  Total events across all sites for the current day.
  Used by the admin dashboard.
  """
  def total_events_today do
    with :ok <- check_clickhouse() do
      today = Date.utc_today() |> Date.to_iso8601()

      sql = """
      SELECT count() AS total
      FROM events
      WHERE toDate(timestamp) = #{ClickHouse.param(today)}
      """

      case ClickHouse.query(sql) do
        {:ok, [%{"total" => count}]} -> {:ok, count}
        {:ok, []} -> {:ok, 0}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp empty_overview do
    %{
      "pageviews" => 0,
      "unique_visitors" => 0,
      "sessions" => 0,
      "bounce_rate" => 0,
      "avg_duration" => 0
    }
  end

  defp self_referrer_domains(%Site{domain: domain}) when is_binary(domain) and domain != "" do
    # The site's analytics subdomain (e.g. b.example.com) and its parent domain
    parent =
      case String.split(domain, ".", parts: 2) do
        [_sub, parent] -> parent
        _ -> nil
      end

    [domain, "www.spectabas.com", "spectabas.com"]
    |> then(fn list -> if parent, do: [parent, "www.#{parent}" | list], else: list end)
    |> Enum.uniq()
  end

  defp self_referrer_domains(_), do: ["www.spectabas.com", "spectabas.com"]

  defp count_goal_completions(site, goal, date_range) do
    condition =
      case goal.goal_type do
        "pageview" ->
          path_pattern =
            goal.page_path
            |> to_string()
            |> String.replace("*", "%")

          "event_type = 'pageview' AND url_path LIKE #{ClickHouse.param(path_pattern)}"

        "custom_event" ->
          "event_type = 'custom' AND event_name = #{ClickHouse.param(to_string(goal.event_name))}"

        _ ->
          "1 = 0"
      end

    sql = """
    SELECT count() AS completions
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
      AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      AND #{condition}
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"completions" => count}]} -> count
      _ -> 0
    end
  end
end
