defmodule Spectabas.Analytics do
  @moduledoc """
  Analytics query layer. All functions verify user access before querying ClickHouse.
  All interpolated values use ClickHouse.param/1 for safety.
  """

  alias Spectabas.{Accounts, ClickHouse}
  alias Spectabas.Analytics.Segment
  alias Spectabas.Sites.Site
  alias Spectabas.Accounts.User

  @doc """
  Overview stats: pageviews, unique_visitors, sessions, bounce_rate, avg_duration.
  """
  def overview_stats(site, user, date_range, opts \\ [])

  def overview_stats(%Site{} = site, %User{} = user, date_range, opts) when is_atom(date_range) do
    overview_stats(site, user, period_to_date_range(date_range), opts)
  end

  def overview_stats(%Site{} = site, %User{} = user, date_range, opts) when is_map(date_range) do
    with :ok <- authorize(site, user),
         :ok <- check_clickhouse() do
      seg = segment_sql(opts)

      sql = """
      SELECT
        sum(pv) AS pageviews,
        uniqExact(visitor_id) AS unique_visitors,
        count() AS total_sessions,
        round(countIf(pv = 1 AND dur = 0 AND ce = 0) / greatest(count(), 1) * 100, 1) AS bounce_rate,
        round(avgIf(dur, dur > 0), 0) AS avg_duration
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS visitor_id,
          countIf(event_type = 'pageview') AS pv,
          maxIf(duration_s, event_type = 'duration') AS dur,
          countIf(event_type = 'custom' AND event_name NOT LIKE '\\_%') AS ce
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          AND ip_is_bot = 0
          #{seg}
        GROUP BY session_id
        HAVING pv > 0
      )
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:ok, empty_overview()}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Time-series data: pageviews and visitors bucketed by time interval.
  Returns a list of %{"bucket" => ..., "pageviews" => ..., "visitors" => ...}.
  """
  def timeseries(%Site{} = site, %User{} = user, date_range) when is_atom(date_range) do
    timeseries(site, user, period_to_date_range(date_range), date_range)
  end

  def timeseries(%Site{} = site, %User{} = user, %{from: _, to: _} = date_range, period) do
    with :ok <- authorize(site, user) do
      tz = site.timezone || "UTC"
      trunc_fn = if period == :day, do: "toStartOfHour", else: "toDate"

      sql = """
      SELECT
        #{trunc_fn}(toTimezone(timestamp, #{ClickHouse.param(tz)})) AS bucket,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
      GROUP BY bucket
      ORDER BY bucket ASC
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          data_map =
            Map.new(rows, fn row ->
              {row["bucket"] || "", {to_int(row["pageviews"]), to_int(row["visitors"])}}
            end)

          all_buckets = generate_buckets(date_range.from, date_range.to, period, tz)

          filled =
            Enum.map(all_buckets, fn {bucket_key, label} ->
              {pv, v} = Map.get(data_map, bucket_key, {0, 0})
              %{"bucket" => bucket_key, "label" => label, "pageviews" => pv, "visitors" => v}
            end)

          {:ok, filled}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generate_buckets(from, to, :day, tz) do
    # Hourly buckets in the site's timezone
    # Convert UTC boundaries to local time for bucket generation
    from_local = to_local(from, tz)
    to_local_dt = to_local(to, tz)

    from_hour =
      from_local |> DateTime.truncate(:second) |> Map.put(:minute, 0) |> Map.put(:second, 0)

    hours = max(div(DateTime.diff(to_local_dt, from_hour, :second), 3600), 1)

    0..hours
    |> Enum.map(fn h ->
      dt = DateTime.add(from_hour, h, :hour)
      bucket = Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      label = Calendar.strftime(dt, "%H:%M")
      {bucket, label}
    end)
  end

  defp generate_buckets(from, to, _period, tz) do
    # Daily buckets in site timezone
    from_date = to_local(from, tz) |> DateTime.to_date()
    to_date = to_local(to, tz) |> DateTime.to_date()
    days = Date.diff(to_date, from_date)

    0..max(days, 0)
    |> Enum.map(fn d ->
      date = Date.add(from_date, d)
      bucket = Date.to_iso8601(date)
      [_, m, dd] = String.split(bucket, "-")
      label = "#{m}/#{dd}"
      {bucket, label}
    end)
  end

  # Convert UTC DateTime to site-local DateTime (for bucket label generation)
  defp to_local(dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> local
      _ -> dt
    end
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(_), do: 0

  @doc """
  Entry pages: first pageview URL per session.
  """
  def entry_pages(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        url_path,
        count() AS entries,
        uniq(visitor_id) AS unique_visitors
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS visitor_id,
          argMin(url_path, timestamp) AS url_path
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview'
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY session_id
      )
      GROUP BY url_path
      ORDER BY entries DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Exit pages: last pageview URL per session.
  """
  def exit_pages(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        url_path,
        count() AS exits,
        uniq(visitor_id) AS unique_visitors
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS visitor_id,
          argMax(url_path, timestamp) AS url_path
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview'
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY session_id
      )
      GROUP BY url_path
      ORDER BY exits DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top pages by pageviews from events table.
  """
  def top_pages(site, user, date_range, opts \\ [])

  def top_pages(%Site{} = site, %User{} = user, date_range, opts) do
    date_range = ensure_date_range(date_range)
    seg = segment_sql(opts)

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
        #{seg}
      GROUP BY url_path
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top traffic sources: referrer_domain with unique session counts.
  Uses raw events table with uniq(session_id) to avoid overcounting.
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
        countIf(event_type = 'pageview') AS pageviews,
        uniq(session_id) AS sessions
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND referrer_domain != ''
        AND ip_is_bot = 0
        #{exclude_clause}
      GROUP BY referrer_domain
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Top UTM sources grouped by utm_source only."
  def top_utm_sources(%Site{} = site, %User{} = user, date_range) do
    top_utm_dimension(site, user, date_range, "utm_source")
  end

  @doc "Top UTM mediums grouped by utm_medium only."
  def top_utm_mediums(%Site{} = site, %User{} = user, date_range) do
    top_utm_dimension(site, user, date_range, "utm_medium")
  end

  @doc "Top UTM campaigns grouped by utm_campaign only."
  def top_utm_campaigns(%Site{} = site, %User{} = user, date_range) do
    top_utm_dimension(site, user, date_range, "utm_campaign")
  end

  @doc "Top UTM terms grouped by utm_term only."
  def top_utm_terms(%Site{} = site, %User{} = user, date_range) do
    top_utm_dimension(site, user, date_range, "utm_term")
  end

  @doc "Top UTM content grouped by utm_content only."
  def top_utm_content(%Site{} = site, %User{} = user, date_range) do
    top_utm_dimension(site, user, date_range, "utm_content")
  end

  defp top_utm_dimension(%Site{} = site, %User{} = user, date_range, dimension) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        #{dimension} AS value,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(session_id) AS sessions
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND #{dimension} != ''
        AND ip_is_bot = 0
      GROUP BY #{dimension}
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Channel breakdown: groups raw sources into marketing channels."
  def channel_breakdown(%Site{} = site, %User{} = user, date_range) do
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
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS visitors,
        uniq(session_id) AS sessions
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
        #{exclude_clause}
      GROUP BY referrer_domain, utm_source, utm_medium
      ORDER BY pageviews DESC
      LIMIT 500
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          channels =
            rows
            |> Enum.group_by(fn row ->
              Spectabas.Analytics.ChannelClassifier.classify(
                row["referrer_domain"] || "",
                row["utm_source"] || "",
                row["utm_medium"] || ""
              )
            end)
            |> Enum.map(fn {channel, rows} ->
              %{
                "channel" => channel,
                "pageviews" =>
                  Enum.sum(Enum.map(rows, &Spectabas.TypeHelpers.to_int(&1["pageviews"]))),
                "visitors" =>
                  Enum.sum(Enum.map(rows, &Spectabas.TypeHelpers.to_int(&1["visitors"]))),
                "sessions" =>
                  Enum.sum(Enum.map(rows, &Spectabas.TypeHelpers.to_int(&1["sessions"]))),
                "sources" => length(rows)
              }
            end)
            |> Enum.sort_by(& &1["pageviews"], :desc)

          {:ok, channels}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Top countries grouped at country level only (for dashboard summary).
  """
  def top_countries_summary(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      # Use raw events — uniqExact across multi-day ranges can't use SummingMergeTree
      sql = """
      SELECT
        ip_country,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_country != ''
        AND ip_is_bot = 0
      GROUP BY ip_country
      ORDER BY unique_visitors DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top regions/states grouped at region level (for dashboard summary).
  """
  def top_regions(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        ip_region_name,
        ip_country,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_region_name != ''
        AND ip_is_bot = 0
      GROUP BY ip_region_name, ip_country
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
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_country != ''
        AND ip_is_bot = 0
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
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
      GROUP BY device_type, browser, os
      ORDER BY pageviews DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top device types by visitors (grouped at device_type level only).
  """
  def top_device_types(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        device_type,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND device_type != ''
        AND ip_is_bot = 0
      GROUP BY device_type
      ORDER BY unique_visitors DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top browsers by visitors (dashboard summary).
  """
  def top_browsers(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        browser AS name,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND browser != ''
        AND ip_is_bot = 0
      GROUP BY browser
      ORDER BY unique_visitors DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top operating systems by visitors (dashboard summary).
  """
  def top_os(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        os AS name,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS unique_visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND os != ''
        AND ip_is_bot = 0
      GROUP BY os
      ORDER BY unique_visitors DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Visitor locations: distinct lat/lon pairs with visitor counts for map plotting.
  """
  def visitor_locations(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        ip_lat,
        ip_lon,
        ip_city,
        ip_region_name,
        ip_country,
        uniq(visitor_id) AS visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_lat != 0
        AND ip_lon != 0
        AND ip_is_bot = 0
      GROUP BY ip_lat, ip_lon, ip_city, ip_region_name, ip_country
      ORDER BY visitors DESC
      LIMIT 200
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Timezone distribution: visitor counts grouped by timezone.
  """
  def timezone_distribution(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        ip_timezone AS timezone,
        uniq(visitor_id) AS visitors,
        count() AS pageviews
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_timezone != ''
      GROUP BY ip_timezone
      ORDER BY visitors DESC
      LIMIT 50
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
      # Stays on raw events table — network_stats MV lacks eu_count
      sql = """
      SELECT
        ip_asn,
        ip_org,
        count() AS hits,
        round(countIf(ip_is_datacenter = 1) / count() * 100, 1) AS datacenter_pct,
        round(countIf(ip_is_vpn = 1) / count() * 100, 1) AS vpn_pct,
        round(countIf(ip_is_tor = 1) / count() * 100, 1) AS tor_pct,
        round(countIf(ip_is_bot = 1) / count() * 100, 1) AS bot_pct,
        round(countIf(ip_is_eu = 1) / count() * 100, 1) AS eu_pct
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
  Active visitors grouped: one row per visitor with their latest activity.
  """
  def realtime_visitors_grouped(%Site{} = site) do
    sql = """
    SELECT
      visitor_id,
      argMax(url_path, timestamp) AS current_page,
      argMax(event_type, timestamp) AS last_event_type,
      countIf(event_type = 'pageview') AS pageviews,
      min(timestamp) AS session_start,
      max(timestamp) AS last_activity,
      any(ip_country) AS country,
      any(ip_city) AS city,
      any(browser) AS browser,
      any(os) AS os,
      any(device_type) AS device_type,
      any(referrer_domain) AS referrer,
      any(visitor_intent) AS intent
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= now() - INTERVAL 5 MINUTE
    GROUP BY visitor_id
    ORDER BY last_activity DESC
    LIMIT 30
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

      if goals == [] do
        {:ok, []}
      else
        # Batch all goals into a single query with UNION ALL
        unions =
          goals
          |> Enum.map(fn goal ->
            condition = goal_condition(goal)

            """
            SELECT #{ClickHouse.param(to_string(goal.id))} AS goal_id, count() AS completions
            FROM events
            WHERE site_id = #{ClickHouse.param(site.id)}
              AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
              AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
              AND #{condition}
            """
          end)
          |> Enum.join("\nUNION ALL\n")

        counts =
          case ClickHouse.query(unions) do
            {:ok, rows} -> Map.new(rows, fn r -> {r["goal_id"], to_int(r["completions"])} end)
            _ -> %{}
          end

        results =
          Enum.map(goals, fn goal ->
            %{
              goal_id: goal.id,
              name: goal.name,
              goal_type: goal.goal_type,
              completions: Map.get(counts, to_string(goal.id), 0)
            }
          end)

        {:ok, results}
      end
    end
  end

  defp goal_condition(goal) do
    case goal.goal_type do
      "pageview" ->
        path_pattern = goal.page_path |> to_string() |> String.replace("*", "%")
        "event_type = 'pageview' AND url_path LIKE #{ClickHouse.param(path_pattern)}"

      "custom_event" ->
        "event_type = 'custom' AND event_name = #{ClickHouse.param(to_string(goal.event_name))}"

      _ ->
        "1 = 0"
    end
  end

  @doc """
  Ecommerce stats: total revenue, orders, avg order value, top products.
  """
  def ecommerce_stats(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      # Filter to site's configured currency to avoid mixing currencies
      site_currency = site.currency || "USD"

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
        AND (currency = #{ClickHouse.param(site_currency)} OR currency = '')
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
    SELECT
      event_type, event_name, url_path, url_host, referrer_domain, referrer_url,
      utm_source, utm_medium, utm_campaign,
      device_type, browser, browser_version, os, os_version,
      screen_width, screen_height, duration_s,
      ip_address, ip_country, ip_country_name, ip_region_name, ip_city,
      ip_timezone, ip_org, ip_is_datacenter, ip_is_vpn, ip_is_tor, ip_is_bot,
      session_id, visitor_intent, user_agent, timestamp
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND visitor_id = #{ClickHouse.param(visitor_id)}
    ORDER BY timestamp ASC
    LIMIT 1000
    """

    ClickHouse.query(sql)
  end

  @doc """
  Aggregated visitor profile stats from ClickHouse events.
  """
  def visitor_profile(%Site{} = site, visitor_id) when is_binary(visitor_id) do
    sql = """
    SELECT
      min(timestamp) AS first_seen,
      max(timestamp) AS last_seen,
      countIf(event_type = 'pageview') AS total_pageviews,
      uniq(session_id) AS total_sessions,
      maxIf(duration_s, event_type = 'duration') AS total_duration,
      argMinIf(url_path, timestamp, event_type = 'pageview') AS first_page,
      argMaxIf(url_path, timestamp, event_type = 'pageview') AS last_page,
      argMinIf(referrer_domain, timestamp, referrer_domain != '') AS original_referrer,
      any(ip_country) AS country,
      any(ip_country_name) AS country_name,
      any(ip_region_name) AS region,
      any(ip_city) AS city,
      any(ip_timezone) AS timezone,
      any(browser) AS browser,
      any(browser_version) AS browser_version,
      any(os) AS os,
      any(os_version) AS os_version,
      any(device_type) AS device_type,
      any(screen_width) AS screen_width,
      any(screen_height) AS screen_height,
      any(ip_org) AS org,
      any(ip_is_datacenter) AS is_datacenter,
      any(ip_is_vpn) AS is_vpn,
      any(ip_is_bot) AS is_bot,
      any(user_agent) AS user_agent,
      any(browser_fingerprint) AS browser_fingerprint,
      groupUniqArray(10)(url_path) AS top_pages,
      groupUniqArray(5)(referrer_domain) AS referrers,
      groupUniqArray(5)(utm_source) AS utm_sources
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND visitor_id = #{ClickHouse.param(visitor_id)}
    """

    case ClickHouse.query(sql) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  @doc """
  Find other visitors who share the same IP address.
  """
  def visitors_by_ip(%Site{} = site, ip_address)
      when is_binary(ip_address) and ip_address != "" do
    sql = """
    SELECT
      visitor_id,
      min(timestamp) AS first_seen,
      max(timestamp) AS last_seen,
      countIf(event_type = 'pageview') AS pageviews,
      any(browser) AS browser,
      any(os) AS os,
      any(device_type) AS device_type
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND ip_address = #{ClickHouse.param(ip_address)}
    GROUP BY visitor_id
    ORDER BY last_seen DESC
    LIMIT 20
    """

    ClickHouse.query(sql)
  end

  def visitors_by_ip(_, _), do: {:ok, []}

  @doc """
  Find other visitors who share the same browser fingerprint.
  Useful for detecting alt accounts, ban evasion, and fraud.
  """
  def visitors_by_fingerprint(%Site{} = site, fingerprint)
      when is_binary(fingerprint) and fingerprint != "" do
    sql = """
    SELECT
      visitor_id,
      min(timestamp) AS first_seen,
      max(timestamp) AS last_seen,
      countIf(event_type = 'pageview') AS pageviews,
      any(browser) AS browser,
      any(os) AS os,
      any(ip_address) AS ip_address,
      any(ip_country) AS country,
      any(ip_city) AS city
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND browser_fingerprint = #{ClickHouse.param(fingerprint)}
    GROUP BY visitor_id
    ORDER BY last_seen DESC
    LIMIT 20
    """

    ClickHouse.query(sql)
  end

  def visitors_by_fingerprint(_, _), do: {:ok, []}

  @doc """
  Get enriched IP data from the most recent event with this IP.
  """
  def ip_details(%Site{} = site, ip_address) when is_binary(ip_address) and ip_address != "" do
    sql = """
    SELECT
      ip_address, ip_country, ip_country_name, ip_continent, ip_continent_name,
      ip_region_code, ip_region_name, ip_city, ip_postal_code,
      ip_lat, ip_lon, ip_accuracy_radius, ip_timezone,
      ip_asn, ip_asn_org, ip_org,
      ip_is_datacenter, ip_is_vpn, ip_is_tor, ip_is_bot
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND ip_address = #{ClickHouse.param(ip_address)}
    ORDER BY timestamp DESC
    LIMIT 1
    """

    case ClickHouse.query(sql) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  def ip_details(_, _), do: {:ok, nil}

  # ---- Visitor Intent ----

  @doc """
  Intent breakdown: visitor counts by classified intent.
  """
  def intent_breakdown(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        visitor_intent AS intent,
        uniq(visitor_id) AS visitors,
        count() AS events
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND visitor_intent != ''
      GROUP BY visitor_intent
      ORDER BY visitors DESC
      """

      ClickHouse.query(sql)
    end
  end

  # ---- Visitor Log ----

  @doc """
  Recent visitors with summary: pages viewed, duration, location, device.
  """
  def visitor_log(site, user, date_range, opts \\ [])

  def visitor_log(%Site{} = site, %User{} = user, date_range, opts) do
    date_range = ensure_date_range(date_range)
    seg = segment_sql(opts)
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    offset = (page - 1) * per_page

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        visitor_id,
        min(timestamp) AS first_seen,
        max(timestamp) AS last_seen,
        countIf(event_type = 'pageview') AS pageviews,
        maxIf(duration_s, event_type = 'duration') AS duration,
        argMinIf(url_path, timestamp, event_type = 'pageview') AS entry_page,
        argMaxIf(url_path, timestamp, event_type = 'pageview') AS exit_page,
        any(ip_country) AS country,
        any(ip_region_name) AS region,
        any(ip_city) AS city,
        any(visitor_intent) AS intent,
        any(browser) AS browser,
        any(os) AS os,
        any(device_type) AS device_type,
        any(referrer_domain) AS referrer
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        #{seg}
      GROUP BY visitor_id
      ORDER BY last_seen DESC
      LIMIT #{per_page} OFFSET #{offset}
      """

      ClickHouse.query(sql)
    end
  end

  # ---- Page Transitions ----

  @doc """
  For a given page, show previous pages (where visitors came from)
  and next pages (where they went).
  """
  def page_transitions(%Site{} = site, %User{} = user, url_path, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      # Previous pages: the page viewed before this one in the same session
      prev_sql = """
      SELECT
        prev_page,
        count() AS transitions
      FROM (
        SELECT
          session_id,
          url_path,
          lagInFrame(url_path) OVER (PARTITION BY session_id ORDER BY timestamp) AS prev_page
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview'
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          AND ip_is_bot = 0
      )
      WHERE url_path = #{ClickHouse.param(url_path)}
        AND prev_page != ''
        AND prev_page != url_path
      GROUP BY prev_page
      ORDER BY transitions DESC
      LIMIT 20
      """

      # Next pages: the page viewed after this one in the same session
      next_sql = """
      SELECT
        next_page,
        count() AS transitions
      FROM (
        SELECT
          session_id,
          url_path,
          leadInFrame(url_path) OVER (PARTITION BY session_id ORDER BY timestamp) AS next_page
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview'
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          AND ip_is_bot = 0
      )
      WHERE url_path = #{ClickHouse.param(url_path)}
        AND next_page != ''
        AND next_page != url_path
      GROUP BY next_page
      ORDER BY transitions DESC
      LIMIT 20
      """

      total_sql = """
      SELECT
        countIf(event_type = 'pageview') AS total_views,
        uniq(visitor_id) AS unique_visitors,
        uniq(session_id) AS sessions
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND url_path = #{ClickHouse.param(url_path)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      """

      with {:ok, prev} <- ClickHouse.query(prev_sql),
           {:ok, next} <- ClickHouse.query(next_sql),
           {:ok, [totals]} <- ClickHouse.query(total_sql) do
        {:ok, %{previous: prev, next: next, totals: totals}}
      end
    end
  end

  # ---- Multi-Channel Attribution ----

  @doc """
  Attribution report: first-touch and last-touch channel for each converting visitor.
  Requires at least one goal to be defined.
  """
  def attribution(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      # First touch: the first non-empty referrer for each visitor
      sql = """
      SELECT
        channel,
        countIf(touch = 'first') AS first_touch,
        countIf(touch = 'last') AS last_touch,
        uniq(visitor_id) AS visitors
      FROM (
        SELECT
          visitor_id,
          argMin(
            if(referrer_domain != '', referrer_domain, if(utm_source != '', utm_source, 'Direct')),
            timestamp
          ) AS first_channel,
          argMax(
            if(referrer_domain != '', referrer_domain, if(utm_source != '', utm_source, 'Direct')),
            timestamp
          ) AS last_channel
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview'
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          AND ip_is_bot = 0
        GROUP BY visitor_id
      )
      ARRAY JOIN
        [first_channel, last_channel] AS channel,
        ['first', 'last'] AS touch
      GROUP BY channel
      ORDER BY visitors DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  # ---- Site Search ----

  @doc """
  Top internal site search queries extracted from URL params.
  Looks for common search params: q, query, search, s, keyword.
  """
  def site_searches(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      # Extract search query from properties._search_query (set during ingest)
      sql = """
      SELECT
        JSONExtractString(properties, '_search_query') AS search_term,
        count() AS searches,
        uniq(visitor_id) AS unique_searchers
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'pageview'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND JSONExtractString(properties, '_search_query') != ''
      GROUP BY search_term
      ORDER BY searches DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  # ---- Cohort Retention ----

  @doc """
  Cohort retention: for visitors first seen in each week, what % returned
  in subsequent weeks. Returns a grid of cohort_week x return_week.
  """
  def cohort_retention(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        cohort_week,
        week_number,
        visitors,
        cohort_size
      FROM (
        SELECT
          toMonday(first_seen) AS cohort_week,
          intDiv(dateDiff('day', first_seen, event_date), 7) AS week_number,
          uniq(visitor_id) AS visitors
        FROM (
          SELECT
            visitor_id,
            toDate(timestamp) AS event_date,
            min(toDate(timestamp)) OVER (PARTITION BY visitor_id) AS first_seen
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
            AND ip_is_bot = 0
        )
        GROUP BY cohort_week, week_number
      ) AS retention
      LEFT JOIN (
        SELECT
          toMonday(min(toDate(timestamp))) AS cohort_week,
          uniq(visitor_id) AS cohort_size
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          AND ip_is_bot = 0
        GROUP BY visitor_id
      ) AS sizes USING (cohort_week)
      ORDER BY cohort_week, week_number
      """

      ClickHouse.query(sql)
    end
  end

  # --- Private helpers ---

  defp segment_sql(opts) do
    segment = Keyword.get(opts, :segment, [])
    Segment.to_sql(segment)
  end

  # ---- Real User Monitoring ----

  @doc """
  Performance overview: median and p75 for key metrics across all pages.
  """
  def rum_overview(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      # Use quantileIf to exclude zero/empty values — metrics can be 0 if
      # loadEventEnd hadn't fired when the event was sent (now fixed in tracker)
      sql = """
      SELECT
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS median_page_load,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS p75_page_load,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'ttfb')),
          toFloat64OrZero(JSONExtractString(properties, 'ttfb')) > 0)) AS median_ttfb,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'ttfb')),
          toFloat64OrZero(JSONExtractString(properties, 'ttfb')) > 0)) AS p75_ttfb,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'fcp')),
          toFloat64OrZero(JSONExtractString(properties, 'fcp')) > 0)) AS median_fcp,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'fcp')),
          toFloat64OrZero(JSONExtractString(properties, 'fcp')) > 0)) AS p75_fcp,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'dom_complete')),
          toFloat64OrZero(JSONExtractString(properties, 'dom_complete')) > 0)) AS median_dom,
        count() AS samples
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_name = '_rum'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:ok, %{}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Core Web Vitals: median and p75 for LCP, CLS, FID.
  FID requires user interaction and is often absent — use quantileIf to exclude zeros.
  CLS can legitimately be 0 (no layout shift), so we only filter on non-empty string.
  """
  def rum_web_vitals(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'lcp')),
          toFloat64OrZero(JSONExtractString(properties, 'lcp')) > 0)) AS median_lcp,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'lcp')),
          toFloat64OrZero(JSONExtractString(properties, 'lcp')) > 0)) AS p75_lcp,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'cls')),
          JSONExtractString(properties, 'cls') != ''), 3) AS median_cls,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'cls')),
          JSONExtractString(properties, 'cls') != ''), 3) AS p75_cls,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'fid')),
          JSONExtractString(properties, 'fid') != '')) AS median_fid,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'fid')),
          JSONExtractString(properties, 'fid') != '')) AS p75_fid,
        count() AS samples
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_name = '_cwv'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:ok, %{}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Performance by page: slowest pages by median page load time.
  """
  def rum_by_page(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        url_path,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS median_load,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS p75_load,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'ttfb')),
          toFloat64OrZero(JSONExtractString(properties, 'ttfb')) > 0)) AS median_ttfb,
        round(avgIf(toFloat64OrZero(JSONExtractString(properties, 'transfer_size')),
          toFloat64OrZero(JSONExtractString(properties, 'transfer_size')) > 0)) AS avg_size,
        count() AS samples
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_name = '_rum'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      GROUP BY url_path
      HAVING samples >= 3
      ORDER BY median_load DESC
      LIMIT 20
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Performance by device type: compare mobile vs desktop load times.
  """
  def rum_by_device(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        device_type,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS median_load,
        round(quantileIf(0.75)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS p75_load,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'fcp')),
          toFloat64OrZero(JSONExtractString(properties, 'fcp')) > 0)) AS median_fcp,
        count() AS samples
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_name = '_rum'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND device_type != ''
      GROUP BY device_type
      ORDER BY samples DESC
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Core Web Vitals per page: LCP, CLS, FID medians for a given URL path.
  Used to surface vitals on Pages and Transitions views.
  """
  def rum_vitals_by_page(%Site{} = site, %User{} = user, date_range, url_path) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'lcp')),
          toFloat64OrZero(JSONExtractString(properties, 'lcp')) > 0)) AS lcp,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'fcp')),
          toFloat64OrZero(JSONExtractString(properties, 'fcp')) > 0)) AS fcp,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS page_load,
        count() AS samples
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_name = '_rum'
        AND url_path = #{ClickHouse.param(url_path)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:ok, %{}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Quick CWV summary for top pages — used on the Pages dashboard.
  Returns LCP + page_load medians grouped by url_path.
  """
  def rum_vitals_summary(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        r.url_path,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(r.properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(r.properties, 'page_load')) > 0)) AS page_load,
        cw.lcp
      FROM events r
      LEFT JOIN (
        SELECT
          url_path,
          round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'lcp')),
            toFloat64OrZero(JSONExtractString(properties, 'lcp')) > 0)) AS lcp
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_name = '_cwv'
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY url_path
      ) cw ON r.url_path = cw.url_path
      WHERE r.site_id = #{ClickHouse.param(site.id)}
        AND r.event_name = '_rum'
        AND r.timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND r.timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      GROUP BY r.url_path, cw.lcp
      ORDER BY page_load DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

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
      sum(pv) AS pageviews,
      uniqExact(visitor_id) AS unique_visitors,
      count() AS total_sessions,
      round(countIf(pv = 1 AND dur = 0) / greatest(count(), 1) * 100, 1) AS bounce_rate,
      round(avgIf(dur, dur > 0), 0) AS avg_duration
    FROM (
      SELECT
        session_id,
        any(visitor_id) AS visitor_id,
        countIf(event_type = 'pageview') AS pv,
        maxIf(duration_s, event_type = 'duration') AS dur
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      GROUP BY session_id
    )
    """

    case ClickHouse.query(sql) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:ok, empty_overview()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Batched overview stats for multiple sites in a single ClickHouse query.
  Returns %{site_id => %{"pageviews" => ..., "unique_visitors" => ...}}.
  """
  def overview_stats_batch(site_ids, date_range) when is_list(site_ids) do
    with :ok <- check_clickhouse() do
      ids = Enum.map_join(site_ids, ",", &ClickHouse.param/1)

      sql = """
      SELECT
        site_id,
        sum(pv) AS pageviews,
        uniqExact(visitor_id) AS unique_visitors
      FROM (
        SELECT
          site_id,
          any(visitor_id) AS visitor_id,
          countIf(event_type = 'pageview') AS pv
        FROM events
        WHERE site_id IN (#{ids})
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          AND ip_is_bot = 0
        GROUP BY site_id, session_id
        HAVING pv > 0
      )
      GROUP BY site_id
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          map =
            Map.new(rows, fn row ->
              {to_int(row["site_id"]), row}
            end)

          {:ok, map}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_date_range(period) when is_atom(period), do: period_to_date_range(period)
  defp ensure_date_range(%{from: _, to: _} = dr), do: dr

  defp period_to_date_range(period), do: period_to_date_range(period, "UTC")

  @doc false
  def period_to_date_range(period, timezone) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from =
      case period do
        :today -> today_start(timezone)
        :day -> DateTime.add(now, -24, :hour)
        :week -> DateTime.add(now, -7, :day)
        :month -> DateTime.add(now, -30, :day)
        :quarter -> DateTime.add(now, -90, :day)
        _ -> DateTime.add(now, -7, :day)
      end

    %{from: from, to: now}
  end

  # Get the start of "today" in the given timezone, converted back to UTC
  defp today_start(tz) do
    case DateTime.now(tz) do
      {:ok, local_now} ->
        local_now
        |> DateTime.to_date()
        |> DateTime.new!(~T[00:00:00], tz)
        |> DateTime.shift_zone!("Etc/UTC")

      _ ->
        # Fallback to UTC if timezone is invalid
        DateTime.new!(Date.utc_today(), ~T[00:00:00])
    end
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
end
