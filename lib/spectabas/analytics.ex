defmodule Spectabas.Analytics do
  @moduledoc """
  Analytics query layer. All functions verify user access before querying ClickHouse.
  All interpolated values use ClickHouse.param/1 for safety.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

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

      # Check if we need to include imported data
      {native_range, import_range} = split_date_range(site, date_range)

      native_result =
        if native_range do
          sql = """
          SELECT
            sum(pv) AS pageviews,
            uniqExact(visitor_id) AS unique_visitors,
            count() AS total_sessions,
            round(countIf(pv = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate,
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
              AND timestamp >= #{ClickHouse.param(format_datetime(native_range.from))}
              AND timestamp <= #{ClickHouse.param(format_datetime(native_range.to))}
              AND ip_is_bot = 0
              #{seg}
            GROUP BY session_id
            HAVING pv > 0
          )
          """

          case ClickHouse.query(sql) do
            {:ok, [row]} -> row
            _ -> nil
          end
        end

      imported_result =
        if import_range do
          sql = """
          SELECT
            sum(pageviews) AS pageviews,
            sum(visitors) AS unique_visitors,
            sum(sessions) AS total_sessions,
            round(sum(bounces) / greatest(sum(sessions), 1) * 100, 1) AS bounce_rate,
            round(sum(total_duration) / greatest(sum(sessions) - sum(bounces), 1), 0) AS avg_duration
          FROM imported_daily_stats
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(import_range.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(import_range.to))}
          """

          case ClickHouse.query(sql) do
            {:ok, [row]} -> row
            _ -> nil
          end
        end

      {:ok, merge_overview(native_result, imported_result)}
    end
  end

  @doc """
  Fast overview stats using daily_stats SummingMergeTree.
  Visitors/sessions are summed per-day (approximate for multi-day ranges).
  Falls back to regular overview_stats if segments are active.
  """
  def overview_stats_fast(%Site{} = site, %User{} = user, date_range, opts \\ []) do
    seg = segment_sql(opts)

    # Segments require raw events — can't use daily_stats MV
    if seg != "" do
      overview_stats(site, user, date_range, opts)
    else
      with :ok <- authorize(site, user),
           :ok <- check_clickhouse() do
        {native_range, import_range} = split_date_range(site, date_range)

        native_result =
          if native_range do
            # Lighter query than full overview_stats: uses uniq() (HyperLogLog) instead of
            # uniqExact + session subquery. Avoids daily_stats SummingMergeTree which
            # incorrectly sums per-batch uniqExact values.
            sql = """
            SELECT
              countIf(event_type = 'pageview') AS pageviews,
              uniq(visitor_id) AS unique_visitors,
              uniq(session_id) AS total_sessions,
              round(sum(is_bounce) / greatest(uniq(session_id), 1) * 100, 1) AS bounce_rate,
              round(avgIf(duration_s, event_type = 'duration' AND duration_s > 0), 0) AS avg_duration
            FROM events
            WHERE site_id = #{ClickHouse.param(site.id)}
              AND timestamp >= #{ClickHouse.param(format_datetime(native_range.from))}
              AND timestamp <= #{ClickHouse.param(format_datetime(native_range.to))}
              AND ip_is_bot = 0
            """

            case ClickHouse.query(sql) do
              {:ok, [row]} -> row
              _ -> nil
            end
          end

        imported_result =
          if import_range do
            sql = """
            SELECT
              sum(pageviews) AS pageviews,
              sum(visitors) AS unique_visitors,
              sum(sessions) AS total_sessions,
              round(sum(bounces) / greatest(sum(sessions), 1) * 100, 1) AS bounce_rate,
              round(sum(total_duration) / greatest(sum(sessions) - sum(bounces), 1), 0) AS avg_duration
            FROM imported_daily_stats
            WHERE site_id = #{ClickHouse.param(site.id)}
              AND date >= #{ClickHouse.param(Date.to_iso8601(import_range.from))}
              AND date <= #{ClickHouse.param(Date.to_iso8601(import_range.to))}
            """

            case ClickHouse.query(sql) do
              {:ok, [row]} -> row
              _ -> nil
            end
          end

        {:ok, merge_overview(native_result, imported_result)}
      end
    end
  end

  defp merge_overview(nil, nil), do: empty_overview()
  defp merge_overview(native, nil), do: native
  defp merge_overview(nil, imported), do: imported

  defp merge_overview(native, imported) do
    n_pv = to_int(native["pageviews"])
    i_pv = to_int(imported["pageviews"])
    n_sess = to_int(native["total_sessions"])
    i_sess = to_int(imported["total_sessions"])
    total_sess = n_sess + i_sess

    bounce_rate =
      if total_sess > 0 do
        (to_float(native["bounce_rate"]) * n_sess +
           to_float(imported["bounce_rate"]) * i_sess) / total_sess
      else
        0.0
      end

    n_dur = to_int(native["avg_duration"])
    i_dur = to_int(imported["avg_duration"])
    n_non_bounce = max(n_sess - round(to_float(native["bounce_rate"]) / 100 * n_sess), 1)
    i_non_bounce = max(i_sess - round(to_float(imported["bounce_rate"]) / 100 * i_sess), 1)
    total_non_bounce = n_non_bounce + i_non_bounce

    avg_duration =
      if total_non_bounce > 0 do
        (n_dur * n_non_bounce + i_dur * i_non_bounce) / total_non_bounce
      else
        0
      end

    %{
      "pageviews" => to_string(n_pv + i_pv),
      "unique_visitors" =>
        to_string(to_int(native["unique_visitors"]) + to_int(imported["unique_visitors"])),
      "total_sessions" => to_string(total_sess),
      "bounce_rate" => to_string(Float.round(bounce_rate, 1)),
      "avg_duration" => to_string(round(avg_duration))
    }
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
      {native_range, import_range} = split_date_range(site, date_range)

      # Native timeseries
      native_rows =
        if native_range do
          sql = """
          SELECT
            #{trunc_fn}(toTimezone(timestamp, #{ClickHouse.param(tz)})) AS bucket,
            countIf(event_type = 'pageview') AS pageviews,
            uniq(visitor_id) AS visitors
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(native_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(native_range.to))}
            AND ip_is_bot = 0
          GROUP BY bucket
          ORDER BY bucket ASC
          """

          case ClickHouse.query(sql) do
            {:ok, rows} -> rows
            _ -> []
          end
        else
          []
        end

      # Imported timeseries (daily granularity only)
      imported_rows =
        if import_range do
          sql = """
          SELECT
            date AS bucket,
            pageviews,
            visitors
          FROM imported_daily_stats
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(import_range.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(import_range.to))}
          ORDER BY date ASC
          """

          case ClickHouse.query(sql) do
            {:ok, rows} -> rows
            _ -> []
          end
        else
          []
        end

      # Merge into a unified data map
      data_map =
        (native_rows ++ imported_rows)
        |> Enum.reduce(%{}, fn row, acc ->
          key = row["bucket"] || ""
          pv = to_int(row["pageviews"])
          v = to_int(row["visitors"])
          {existing_pv, existing_v} = Map.get(acc, key, {0, 0})
          Map.put(acc, key, {existing_pv + pv, existing_v + v})
        end)

      all_buckets = generate_buckets(date_range.from, date_range.to, period, tz)

      filled =
        Enum.map(all_buckets, fn {bucket_key, label} ->
          {pv, v} = Map.get(data_map, bucket_key, {0, 0})
          %{"bucket" => bucket_key, "label" => label, "pageviews" => pv, "visitors" => v}
        end)

      {:ok, filled}
    end
  end

  @doc """
  Fast timeseries using pre-aggregated daily_stats (SummingMergeTree).
  Used for date ranges >= 30 days where hourly granularity is not needed.
  Returns the same format as timeseries/4.
  """
  def timeseries_fast(%Site{} = site, %User{} = user, %{from: _, to: _} = date_range, period) do
    with :ok <- authorize(site, user) do
      tz = site.timezone || "UTC"
      {native_range, import_range} = split_date_range(site, date_range)

      # Query pre-aggregated daily_stats (SummingMergeTree — must SUM columns)
      native_rows =
        if native_range do
          from_date = native_range.from |> to_local(tz) |> DateTime.to_date() |> Date.to_iso8601()
          to_date = native_range.to |> to_local(tz) |> DateTime.to_date() |> Date.to_iso8601()

          # Query raw events with uniq() (HyperLogLog) for accurate daily visitor counts.
          # daily_stats SummingMergeTree incorrectly sums per-batch uniqExact values.
          sql = """
          SELECT
            toString(toDate(timestamp)) AS bucket,
            countIf(event_type = 'pageview' AND ip_is_bot = 0) AS pageviews,
            uniqIf(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS visitors
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(from_date <> " 00:00:00")}
            AND timestamp <= #{ClickHouse.param(to_date <> " 23:59:59")}
            AND ip_is_bot = 0
          GROUP BY toDate(timestamp)
          ORDER BY bucket ASC
          """

          case ClickHouse.query(sql) do
            {:ok, rows} -> rows
            _ -> []
          end
        else
          []
        end

      # Imported timeseries (same as regular timeseries)
      imported_rows =
        if import_range do
          sql = """
          SELECT
            date AS bucket,
            pageviews,
            visitors
          FROM imported_daily_stats
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(import_range.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(import_range.to))}
          ORDER BY date ASC
          """

          case ClickHouse.query(sql) do
            {:ok, rows} -> rows
            _ -> []
          end
        else
          []
        end

      # Merge into a unified data map
      data_map =
        (native_rows ++ imported_rows)
        |> Enum.reduce(%{}, fn row, acc ->
          key = row["bucket"] || ""
          pv = to_int(row["pageviews"])
          v = to_int(row["visitors"])
          {existing_pv, existing_v} = Map.get(acc, key, {0, 0})
          Map.put(acc, key, {existing_pv + pv, existing_v + v})
        end)

      all_buckets = generate_buckets(date_range.from, date_range.to, period, tz)

      filled =
        Enum.map(all_buckets, fn {bucket_key, label} ->
          {pv, v} = Map.get(data_map, bucket_key, {0, 0})
          %{"bucket" => bucket_key, "label" => label, "pageviews" => pv, "visitors" => v}
        end)

      {:ok, filled}
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

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n / 1

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

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
        uniq(visitor_id) AS unique_visitors,
        round(countIf(pv = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate,
        round(avg(coalesce(dur, 0)), 0) AS avg_duration
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS visitor_id,
          argMin(url_path, timestamp) AS url_path,
          countIf(event_type = 'pageview') AS pv,
          maxIf(duration_s, event_type = 'duration' AND duration_s > 0) AS dur
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY session_id
        HAVING countIf(event_type = 'pageview') > 0
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
        uniq(visitor_id) AS unique_visitors,
        round(avg(coalesce(dur, 0)), 0) AS avg_duration
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS visitor_id,
          argMax(url_path, timestamp) AS url_path,
          maxIf(duration_s, event_type = 'duration' AND duration_s > 0) AS dur
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY session_id
        HAVING countIf(event_type = 'pageview') > 0
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
      import_aware_query(
        site,
        date_range,
        fn nr ->
          """
          SELECT url_path, countIf(event_type = 'pageview') AS pageviews,
            uniqIf(visitor_id, event_type = 'pageview') AS unique_visitors,
            round(avgIf(duration_s, event_type = 'duration' AND duration_s > 0), 0) AS avg_duration
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND event_type IN ('pageview', 'duration')
            AND timestamp >= #{ClickHouse.param(format_datetime(nr.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(nr.to))}
            AND ip_is_bot = 0 #{seg}
          GROUP BY url_path ORDER BY pageviews DESC LIMIT 100
          """
        end,
        fn ir ->
          """
          SELECT url_path, sum(pageviews) AS pageviews, sum(visitors) AS unique_visitors, 0 AS avg_duration
          FROM imported_pages
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(ir.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(ir.to))}
          GROUP BY url_path ORDER BY pageviews DESC LIMIT 100
          """
        end,
        fn row -> row["url_path"] end,
        fn rows ->
          %{
            "url_path" => List.first(rows)["url_path"],
            "pageviews" => to_string(sum_field(rows, "pageviews")),
            "unique_visitors" => to_string(sum_field(rows, "unique_visitors")),
            "avg_duration" => to_string(sum_field(rows, "avg_duration"))
          }
        end
      )
      |> case do
        {:ok, rows} -> {:ok, Enum.sort_by(rows, &(-to_int(&1["pageviews"]))) |> Enum.take(100)}
        error -> error
      end
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

      import_aware_query(
        site,
        date_range,
        fn nr ->
          """
          SELECT referrer_domain, countIf(event_type = 'pageview') AS pageviews, uniq(session_id) AS sessions
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(nr.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(nr.to))}
            AND referrer_domain != '' AND ip_is_bot = 0 #{exclude_clause}
          GROUP BY referrer_domain ORDER BY pageviews DESC LIMIT 100
          """
        end,
        fn ir ->
          """
          SELECT referrer_domain, sum(pageviews) AS pageviews, sum(sessions) AS sessions
          FROM imported_sources
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(ir.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(ir.to))}
            AND referrer_domain != ''
          GROUP BY referrer_domain ORDER BY pageviews DESC LIMIT 100
          """
        end,
        fn row -> row["referrer_domain"] end,
        fn rows ->
          %{
            "referrer_domain" => List.first(rows)["referrer_domain"],
            "pageviews" => to_string(sum_field(rows, "pageviews")),
            "sessions" => to_string(sum_field(rows, "sessions"))
          }
        end
      )
      |> case do
        {:ok, rows} -> {:ok, Enum.sort_by(rows, &(-to_int(&1["pageviews"]))) |> Enum.take(100)}
        error -> error
      end
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

  @doc "Campaign performance: visitors, sessions, bounce rate, avg duration per utm_campaign."
  def campaign_performance(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        campaign,
        sum(pv) AS pageviews,
        uniq(visitor_id) AS visitors,
        count() AS sessions,
        round(countIf(pv = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate,
        round(avg(coalesce(dur, 0)), 0) AS avg_duration
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS visitor_id,
          any(utm_campaign) AS campaign,
          countIf(event_type = 'pageview') AS pv,
          maxIf(duration_s, event_type = 'duration' AND duration_s > 0) AS dur
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND utm_campaign != ''
          AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY session_id
        HAVING pv > 0
      )
      GROUP BY campaign
      ORDER BY visitors DESC
      LIMIT 50
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

      channel_sql = channel_case_expression()

      # Three levels: event (compute channel) → session (bounce/duration) → group
      sql = """
      SELECT
        channel,
        sum(pv) AS pageviews,
        uniq(visitor_id) AS visitors,
        count() AS sessions,
        uniq(ref_domain) AS sources,
        round(countIf(pv = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate,
        round(avg(coalesce(dur, 0)), 0) AS avg_duration,
        round(sum(pv) / greatest(count(), 1), 1) AS pages_per_session
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS visitor_id,
          any(ref_domain) AS ref_domain,
          any(channel) AS channel,
          sum(is_pv) AS pv,
          max(dur) AS dur
        FROM (
          SELECT
            session_id,
            visitor_id,
            referrer_domain AS ref_domain,
            (#{channel_sql}) AS channel,
            if(event_type = 'pageview', 1, 0) AS is_pv,
            if(event_type = 'duration' AND duration_s > 0, duration_s, 0) AS dur
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
            AND ip_is_bot = 0
            #{exclude_clause}
        )
        GROUP BY session_id
        HAVING pv > 0
      )
      GROUP BY channel
      ORDER BY pageviews DESC
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Drill down into a specific channel — shows individual sources within that channel.
  """
  def channel_detail(%Site{} = site, %User{} = user, date_range, channel_name) do
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

      # Same channel classification as channel_breakdown
      channel_sql = channel_case_expression()

      sql = """
      SELECT
        if(referrer_domain != '', referrer_domain, if(utm_source != '', utm_source, 'Direct')) AS source,
        countIf(event_type = 'pageview') AS pageviews,
        uniq(visitor_id) AS visitors,
        uniq(session_id) AS sessions
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
        AND event_type = 'pageview'
        AND (#{channel_sql}) = #{ClickHouse.param(channel_name)}
        #{exclude_clause}
      GROUP BY source
      ORDER BY pageviews DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  # Shared ClickHouse CASE expression for channel classification
  defp channel_case_expression do
    """
    multiIf(
      lower(utm_medium) IN ('paid_social', 'paidsocial'), 'Paid Social',
      lower(utm_medium) IN ('cpc', 'ppc', 'paidsearch', 'paid'), 'Paid Search',
      lower(utm_medium) = 'email', 'Email',
      lower(utm_medium) = 'social', 'Social Networks',
      referrer_domain = '' AND utm_source = '', 'Direct',
      multiSearchAnyCaseInsensitive(referrer_domain, ['chatgpt.com', 'chat.openai.com', 'claude.ai', 'perplexity.ai', 'gemini.google.com', 'copilot.microsoft.com', 'poe.com', 'you.com', 'phind.com']) > 0, 'AI Assistants',
      multiSearchAnyCaseInsensitive(referrer_domain, ['mail.google.com', 'outlook.live.com', 'mail.yahoo.com', 'webmail']) > 0, 'Email',
      multiSearchAnyCaseInsensitive(referrer_domain, ['google.com', 'google.co', 'bing.com', 'duckduckgo.com', 'yahoo.com', 'baidu.com', 'yandex.ru', 'yandex.com', 'ecosia.org', 'brave.com', 'search.brave.com']) > 0, 'Search Engines',
      multiSearchAnyCaseInsensitive(referrer_domain, ['facebook.com', 'fb.com', 'instagram.com', 'twitter.com', 'x.com', 'linkedin.com', 'reddit.com', 'tiktok.com', 'youtube.com', 'pinterest.com', 'threads.net', 'mastodon.social']) > 0, 'Social Networks',
      referrer_domain != '', 'Websites',
      utm_source != '', 'Other Campaigns',
      'Direct'
    )
    """
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
      import_aware_query(
        site,
        date_range,
        fn nr ->
          """
          SELECT ip_region_name, ip_country, countIf(event_type = 'pageview') AS pageviews,
            uniq(visitor_id) AS unique_visitors
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(nr.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(nr.to))}
            AND ip_region_name != '' AND ip_is_bot = 0
          GROUP BY ip_region_name, ip_country ORDER BY unique_visitors DESC LIMIT 100
          """
        end,
        fn ir ->
          """
          SELECT ip_country_name AS ip_region_name, ip_country,
            sum(pageviews) AS pageviews, sum(visitors) AS unique_visitors
          FROM imported_countries
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(ir.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(ir.to))}
            AND ip_country != ''
          GROUP BY ip_country, ip_country_name ORDER BY unique_visitors DESC LIMIT 100
          """
        end,
        fn row -> {row["ip_country"], row["ip_region_name"]} end,
        fn rows ->
          %{
            "ip_region_name" => List.first(rows)["ip_region_name"],
            "ip_country" => List.first(rows)["ip_country"],
            "pageviews" => to_string(sum_field(rows, "pageviews")),
            "unique_visitors" => to_string(sum_field(rows, "unique_visitors"))
          }
        end
      )
      |> case do
        {:ok, rows} ->
          {:ok, Enum.sort_by(rows, &(-to_int(&1["unique_visitors"]))) |> Enum.take(100)}

        error ->
          error
      end
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
      import_aware_query(
        site,
        date_range,
        fn nr ->
          """
          SELECT browser AS name, countIf(event_type = 'pageview') AS pageviews,
            uniq(visitor_id) AS unique_visitors
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(nr.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(nr.to))}
            AND browser != '' AND ip_is_bot = 0
          GROUP BY browser ORDER BY unique_visitors DESC LIMIT 100
          """
        end,
        fn ir ->
          """
          SELECT browser AS name, sum(pageviews) AS pageviews, sum(visitors) AS unique_visitors
          FROM imported_devices
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(ir.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(ir.to))}
            AND browser != ''
          GROUP BY browser ORDER BY unique_visitors DESC LIMIT 100
          """
        end,
        fn row -> row["name"] end,
        fn rows ->
          %{
            "name" => List.first(rows)["name"],
            "pageviews" => to_string(sum_field(rows, "pageviews")),
            "unique_visitors" => to_string(sum_field(rows, "unique_visitors"))
          }
        end
      )
      |> case do
        {:ok, rows} ->
          {:ok, Enum.sort_by(rows, &(-to_int(&1["unique_visitors"]))) |> Enum.take(100)}

        error ->
          error
      end
    end
  end

  @doc """
  Top operating systems by visitors (dashboard summary).
  """
  def top_os(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      import_aware_query(
        site,
        date_range,
        fn nr ->
          """
          SELECT os AS name, countIf(event_type = 'pageview') AS pageviews,
            uniq(visitor_id) AS unique_visitors
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(nr.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(nr.to))}
            AND os != '' AND ip_is_bot = 0
          GROUP BY os ORDER BY unique_visitors DESC LIMIT 100
          """
        end,
        fn ir ->
          """
          SELECT os AS name, sum(pageviews) AS pageviews, sum(visitors) AS unique_visitors
          FROM imported_devices
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND date >= #{ClickHouse.param(Date.to_iso8601(ir.from))}
            AND date <= #{ClickHouse.param(Date.to_iso8601(ir.to))}
            AND os != ''
          GROUP BY os ORDER BY unique_visitors DESC LIMIT 100
          """
        end,
        fn row -> row["name"] end,
        fn rows ->
          %{
            "name" => List.first(rows)["name"],
            "pageviews" => to_string(sum_field(rows, "pageviews")),
            "unique_visitors" => to_string(sum_field(rows, "unique_visitors"))
          }
        end
      )
      |> case do
        {:ok, rows} ->
          {:ok, Enum.sort_by(rows, &(-to_int(&1["unique_visitors"]))) |> Enum.take(100)}

        error ->
          error
      end
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
        AND ip_is_bot = 0
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
        countIf(event_type = 'pageview') AS pageviews
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
        AND ip_timezone != ''
      GROUP BY ip_timezone
      ORDER BY visitors DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Bot traffic overview: total events, bot vs human breakdown, bot types.
  """
  def bot_stats(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        count() AS total_events,
        countIf(ip_is_bot = 1) AS bot_events,
        countIf(ip_is_bot = 0) AS human_events,
        round(countIf(ip_is_bot = 1) / greatest(count(), 1) * 100, 1) AS bot_pct,
        uniqIf(visitor_id, ip_is_bot = 1) AS bot_visitors,
        uniqIf(visitor_id, ip_is_bot = 0) AS human_visitors,
        countIf(ip_is_bot = 1 AND ip_is_datacenter = 1) AS datacenter_bots,
        countIf(ip_is_bot = 1 AND ip_is_vpn = 1) AS vpn_bots,
        countIf(ip_is_bot = 1 AND ip_is_tor = 1) AS tor_bots
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
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
  Top bot sources: which user agents, IPs, and pages bots hit most.
  """
  def bot_top_pages(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        url_path,
        count() AS hits,
        uniq(visitor_id) AS bots
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 1
        AND event_type = 'pageview'
      GROUP BY url_path
      ORDER BY hits DESC
      LIMIT 20
      """

      ClickHouse.query(sql)
    end
  end

  @doc """
  Top bot user agents.
  """
  def bot_top_user_agents(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        user_agent,
        count() AS hits,
        uniq(visitor_id) AS bots
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 1
      GROUP BY user_agent
      ORDER BY hits DESC
      LIMIT 20
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
    tz = tz_sql(site)

    sql = """
    SELECT
      event_type,
      url_path,
      referrer_domain,
      ip_country,
      device_type,
      browser,
      visitor_id,
      toTimezone(timestamp, #{tz}) AS timestamp
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
    tz = tz_sql(site)

    sql = """
    SELECT
      visitor_id,
      argMax(url_path, timestamp) AS current_page,
      argMax(event_type, timestamp) AS last_event_type,
      countIf(event_type = 'pageview') AS pageviews,
      toTimezone(min(timestamp), #{tz}) AS session_start,
      toTimezone(max(timestamp), #{tz}) AS last_activity,
      any(ip_country) AS country,
      any(ip_region_name) AS region,
      any(ip_city) AS city,
      any(browser) AS browser,
      any(os) AS os,
      any(device_type) AS device_type,
      any(referrer_domain) AS referrer,
      any(visitor_intent) AS intent,
      anyIf(click_id_type, click_id_type != '') AS click_id_type
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= now() - INTERVAL 5 MINUTE
    GROUP BY visitor_id
    ORDER BY last_activity DESC
    LIMIT 100
    """

    ClickHouse.query(sql)
  end

  # ---- Revenue & Conversion Analytics ----

  @doc """
  Revenue attribution by traffic source dimension.
  - group_by: "source", "medium", "campaign", "term", "content"
  - touch: "first" (first-touch attribution) or "last" (last-touch)
  """
  def revenue_by_source(%Site{} = site, %User{} = user, date_range, opts \\ []) do
    date_range = ensure_date_range(date_range)
    group_by = Keyword.get(opts, :group_by, "source")
    touch = Keyword.get(opts, :touch, "first")

    with :ok <- authorize(site, user) do
      ref = clean_referrer_sql(site)

      source_expr =
        case group_by do
          "campaign" ->
            "if(utm_campaign != '', utm_campaign, '(none)')"

          "medium" ->
            "if(utm_medium != '', utm_medium, '(none)')"

          "term" ->
            "if(utm_term != '', utm_term, '(none)')"

          "content" ->
            "if(utm_content != '', utm_content, '(none)')"

          _ ->
            "if(#{ref} != '', #{ref}, if(utm_source != '', utm_source, 'Direct'))"
        end

      # Only consider events with a real attribution signal (external referrer,
      # UTM param, or click ID). Internal navigations (self-referrals cleaned to
      # empty, no UTMs) evaluate to "Direct" and would incorrectly override real
      # sources in first/last touch attribution.
      has_signal =
        "(#{ref} != '' OR utm_source != '' OR utm_medium != '' OR utm_campaign != '' OR click_id != '')"

      if touch == "any" do
        # "Any touch" works fine — has_signal filter keeps the subquery small
        visitor_source_subquery = """
        SELECT visitor_id, source, ad_platform
        FROM (
          SELECT visitor_id, #{source_expr} AS source, click_id_type AS ad_platform
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND event_type = 'pageview' AND ip_is_bot = 0
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
            AND #{has_signal}
        )
        GROUP BY visitor_id, source, ad_platform
        """

        sql = """
        SELECT
          source,
          ad_platform,
          uniq(e.visitor_id) AS visitors,
          countDistinct(ec.order_id) AS orders,
          sum(ec.revenue) AS total_revenue,
          round(sum(ec.revenue) / greatest(countDistinct(ec.order_id), 1), 2) AS avg_order_value,
          round(countDistinct(ec.order_id) / greatest(uniq(e.visitor_id), 1) * 100, 2) AS conversion_rate
        FROM (
          #{visitor_source_subquery}
        ) AS e
        LEFT JOIN (
          SELECT visitor_id, order_id, revenue
          FROM ecommerce_events
          WHERE site_id = #{ClickHouse.param(site.id)}
            #{ecommerce_source_filter(site)}
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        ) AS ec ON e.visitor_id = ec.visitor_id
        GROUP BY source, ad_platform
        ORDER BY total_revenue DESC
        LIMIT 50
        """

        ClickHouse.query(sql)
      else
        # First/last touch: two parallel flat queries to avoid timeout.
        # Filter to events WITH a signal (referrer, UTM, click ID) to avoid
        # scanning the full events table — visitors with no signal are "Direct"
        # and not useful in attribution. This matches the "any" touch approach.
        agg_fn = if touch == "last", do: "argMax", else: "argMin"
        site_p = ClickHouse.param(site.id)
        from_p = ClickHouse.param(format_datetime(date_range.from))
        to_p = ClickHouse.param(format_datetime(date_range.to))

        visitors_sql = """
        SELECT source, ad_platform, count() AS visitors
        FROM (
          SELECT visitor_id,
            #{agg_fn}(#{source_expr}, timestamp) AS source,
            #{agg_fn}(click_id_type, timestamp) AS ad_platform
          FROM events
          WHERE site_id = #{site_p}
            AND event_type = 'pageview' AND ip_is_bot = 0
            AND #{has_signal}
            AND timestamp >= #{from_p} AND timestamp <= #{to_p}
          GROUP BY visitor_id
        )
        GROUP BY source, ad_platform
        """

        revenue_sql = """
        SELECT source, ad_platform,
          countDistinct(ec.order_id) AS orders,
          sum(ec.revenue) AS total_revenue,
          round(sum(ec.revenue) / greatest(countDistinct(ec.order_id), 1), 2) AS avg_order_value
        FROM (
          SELECT visitor_id,
            #{agg_fn}(#{source_expr}, timestamp) AS source,
            #{agg_fn}(click_id_type, timestamp) AS ad_platform
          FROM events
          WHERE site_id = #{site_p}
            AND event_type = 'pageview' AND ip_is_bot = 0
            AND #{has_signal}
            AND timestamp >= #{from_p} AND timestamp <= #{to_p}
            AND visitor_id IN (
              SELECT DISTINCT visitor_id FROM ecommerce_events
              WHERE site_id = #{site_p}
                #{ecommerce_source_filter(site)}
                AND timestamp >= #{from_p} AND timestamp <= #{to_p}
            )
          GROUP BY visitor_id
        ) AS e
        INNER JOIN (
          SELECT visitor_id, order_id, revenue
          FROM ecommerce_events
          WHERE site_id = #{site_p}
            #{ecommerce_source_filter(site)}
            AND timestamp >= #{from_p} AND timestamp <= #{to_p}
        ) AS ec ON e.visitor_id = ec.visitor_id
        GROUP BY source, ad_platform
        """

        visitors_task = Task.async(fn -> ClickHouse.query(visitors_sql) end)
        revenue_task = Task.async(fn -> ClickHouse.query(revenue_sql) end)

        visitors_result = Task.await(visitors_task, 30_000)
        revenue_result = Task.await(revenue_task, 30_000)

        visitors_map =
          case visitors_result do
            {:ok, rows} ->
              Map.new(rows, fn r ->
                {{r["source"], r["ad_platform"]}, to_int(r["visitors"])}
              end)

            {:error, reason} ->
              Logger.warning("[RevAttribution] visitors query failed: #{inspect(reason) |> String.slice(0, 200)}")
              %{}
          end

        revenue_map =
          case revenue_result do
            {:ok, rows} ->
              Map.new(rows, fn r ->
                {{r["source"], r["ad_platform"]}, r}
              end)

            {:error, reason} ->
              Logger.warning("[RevAttribution] revenue query failed: #{inspect(reason) |> String.slice(0, 200)}")
              %{}
          end

        all_keys =
          MapSet.union(
            MapSet.new(Map.keys(visitors_map)),
            MapSet.new(Map.keys(revenue_map))
          )

        rows =
          Enum.map(all_keys, fn {source, ad_platform} = key ->
            visitors = Map.get(visitors_map, key, 0)
            rev = Map.get(revenue_map, key, %{})
            orders = to_int(Map.get(rev, "orders", "0"))

            %{
              "source" => source,
              "ad_platform" => ad_platform,
              "visitors" => to_string(visitors),
              "orders" => Map.get(rev, "orders", "0"),
              "total_revenue" => Map.get(rev, "total_revenue", "0"),
              "avg_order_value" => Map.get(rev, "avg_order_value", "0"),
              "conversion_rate" =>
                if(visitors > 0,
                  do: to_string(Float.round(orders / visitors * 100, 2)),
                  else: "0"
                )
            }
          end)

        {:ok,
         rows
         |> Enum.sort_by(fn r -> -to_float(r["total_revenue"]) end)
         |> Enum.take(50)}
      end
    end
  end

  @doc "Ad spend by campaign for ROAS calculation."
  def ad_spend_by_campaign(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        campaign_name,
        campaign_id,
        platform,
        sum(spend) AS total_spend,
        sum(clicks) AS total_clicks,
        sum(impressions) AS total_impressions
      FROM ad_spend FINAL
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND date >= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.from)))}
        AND date <= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.to)))}
      GROUP BY campaign_name, campaign_id, platform
      ORDER BY total_spend DESC
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Ad spend totals across all platforms for a site."
  def ad_spend_totals(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        sum(spend) AS total_spend,
        sum(clicks) AS total_clicks,
        sum(impressions) AS total_impressions,
        count(DISTINCT platform) AS platforms
      FROM ad_spend FINAL
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND date >= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.from)))}
        AND date <= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.to)))}
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Revenue attributed to ad platforms via click IDs (gclid/msclkid/fbclid)."
  def ad_revenue_by_platform(%Site{} = site, %User{} = user, date_range, opts \\ []) do
    date_range = ensure_date_range(date_range)
    touch = Keyword.get(opts, :touch, "last")

    visitor_click_subquery =
      if touch == "any" do
        """
        SELECT visitor_id, click_id_type
        FROM (
          SELECT visitor_id, click_id_type
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND click_id != '' AND click_id_type != ''
            AND event_type = 'pageview' AND ip_is_bot = 0
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        )
        GROUP BY visitor_id, click_id_type
        """
      else
        agg_fn = if touch == "last", do: "argMax", else: "argMin"

        """
        SELECT visitor_id, #{agg_fn}(click_id_type, timestamp) AS click_id_type
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND click_id != '' AND click_id_type != ''
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY visitor_id
        """
      end

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        click_id_type AS platform,
        uniq(e.visitor_id) AS visitors,
        countDistinct(ec.order_id) AS orders,
        sum(ec.revenue) AS total_revenue
      FROM (
        #{visitor_click_subquery}
      ) AS e
      LEFT JOIN (
        SELECT visitor_id, order_id, revenue
        FROM ecommerce_events
        WHERE site_id = #{ClickHouse.param(site.id)}
          #{ecommerce_source_filter(site)}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      ) AS ec ON e.visitor_id = ec.visitor_id
      GROUP BY click_id_type
      ORDER BY total_revenue DESC
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Ad spend by platform for per-platform summary cards."
  def ad_spend_by_platform(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        platform,
        sum(spend) AS total_spend,
        sum(clicks) AS total_clicks,
        sum(impressions) AS total_impressions
      FROM ad_spend FINAL
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND date >= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.from)))}
        AND date <= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.to)))}
      GROUP BY platform
      ORDER BY total_spend DESC
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Ad campaign churn: visitors, churned, retained, purchased, churn rate per campaign."
  def ad_churn_by_campaign(%Site{} = site, %User{} = user, date_range, opts \\ []) do
    date_range = ensure_date_range(date_range)
    group_by = Keyword.get(opts, :group_by, "platform")

    with :ok <- authorize(site, user) do
      {group_col, select_col} =
        if group_by == "campaign" do
          {"if(utm_campaign != '', utm_campaign, '(none)')", "campaign"}
        else
          {"click_id_type", "platform"}
        end

      sql = """
      WITH ad_visitors AS (
        SELECT
          #{group_col} AS #{select_col},
          visitor_id
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND click_id != ''
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY #{select_col}, visitor_id
      ),
      recent AS (
        SELECT
          visitor_id,
          countIf(timestamp >= now() - INTERVAL 14 DAY) AS sessions_recent,
          countIf(timestamp >= now() - INTERVAL 28 DAY AND timestamp < now() - INTERVAL 14 DAY) AS sessions_prior
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND timestamp >= now() - INTERVAL 28 DAY
          AND visitor_id IN (SELECT visitor_id FROM ad_visitors)
        GROUP BY visitor_id
      ),
      purchases AS (
        SELECT DISTINCT visitor_id
        FROM ecommerce_events
        WHERE site_id = #{ClickHouse.param(site.id)}
          #{ecommerce_source_filter(site)}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      )
      SELECT
        av.#{select_col},
        count(DISTINCT av.visitor_id) AS total_visitors,
        countIf(r.sessions_prior > 0 AND r.sessions_recent <= r.sessions_prior / 2) AS churned,
        countIf(NOT (r.sessions_prior > 0 AND r.sessions_recent <= r.sessions_prior / 2)) AS retained,
        countIf(p.visitor_id != '') AS purchased,
        round(countIf(r.sessions_prior > 0 AND r.sessions_recent <= r.sessions_prior / 2) / greatest(count(DISTINCT av.visitor_id), 1) * 100, 1) AS churn_rate
      FROM ad_visitors AS av
      LEFT JOIN recent AS r ON av.visitor_id = r.visitor_id
      LEFT JOIN purchases AS p ON av.visitor_id = p.visitor_id
      GROUP BY av.#{select_col}
      ORDER BY total_visitors DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Overall ad churn rate vs organic churn rate comparison."
  def ad_churn_summary(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      WITH visitor_source AS (
        SELECT
          visitor_id,
          maxIf(1, click_id != '') AS is_ad
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY visitor_id
      ),
      recent AS (
        SELECT
          visitor_id,
          countIf(timestamp >= now() - INTERVAL 14 DAY) AS sessions_recent,
          countIf(timestamp >= now() - INTERVAL 28 DAY AND timestamp < now() - INTERVAL 14 DAY) AS sessions_prior
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND timestamp >= now() - INTERVAL 28 DAY
          AND visitor_id IN (SELECT visitor_id FROM visitor_source)
        GROUP BY visitor_id
      )
      SELECT
        if(vs.is_ad = 1, 'ad', 'organic') AS source_type,
        count() AS total_visitors,
        countIf(r.sessions_prior > 0 AND r.sessions_recent <= r.sessions_prior / 2) AS churned,
        countIf(NOT (r.sessions_prior > 0 AND r.sessions_recent <= r.sessions_prior / 2)) AS retained,
        round(countIf(r.sessions_prior > 0 AND r.sessions_recent <= r.sessions_prior / 2) / greatest(count(), 1) * 100, 1) AS churn_rate
      FROM visitor_source AS vs
      LEFT JOIN recent AS r ON vs.visitor_id = r.visitor_id
      GROUP BY source_type
      ORDER BY source_type
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Avg/median days and sessions from first ad click to first purchase, grouped by platform or campaign."
  def time_to_convert_by_source(%Site{} = site, %User{} = user, date_range, opts \\ []) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      {group_col, result_col} =
        if opts[:group_by] == "campaign",
          do: {"if(utm_campaign != '', utm_campaign, '(none)')", "campaign"},
          else: {"click_id_type", "platform"}

      # Simple approach: get ad visitors who also purchased, compute days between
      # first click event and first purchase per visitor, then aggregate by group
      sql = """
      SELECT
        group_val AS #{result_col},
        count() AS converters,
        round(avg(days_to_convert), 1) AS avg_days,
        round(median(days_to_convert), 1) AS median_days,
        round(avg(sessions), 1) AS avg_sessions,
        round(median(sessions), 1) AS median_sessions
      FROM (
        SELECT
          e.visitor_id,
          any(#{group_col}) AS group_val,
          dateDiff('day', min(e.timestamp), min(ec.purchase_at)) AS days_to_convert,
          uniqExact(e.session_id) AS sessions
        FROM events AS e
        INNER JOIN (
          SELECT visitor_id, min(timestamp) AS purchase_at
          FROM ecommerce_events
          WHERE site_id = #{ClickHouse.param(site.id)}
            #{ecommerce_source_filter(site)}
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          GROUP BY visitor_id
        ) AS ec ON e.visitor_id = ec.visitor_id
        WHERE e.site_id = #{ClickHouse.param(site.id)}
          AND e.event_type = 'pageview' AND e.ip_is_bot = 0
          AND e.click_id != ''
          AND e.timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND e.timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY e.visitor_id
      )
      GROUP BY group_val
      ORDER BY converters DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Histogram of days-to-convert for ad visitors who purchased."
  def time_to_convert_distribution(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT bucket, bucket_order, count() AS visitors
      FROM (
        SELECT
          multiIf(
            days = 0, 'Same day', days = 1, '1 day', days <= 3, '2-3 days',
            days <= 7, '4-7 days', days <= 14, '8-14 days', days <= 30, '15-30 days', '30+ days'
          ) AS bucket,
          multiIf(days = 0, 1, days = 1, 2, days <= 3, 3, days <= 7, 4, days <= 14, 5, days <= 30, 6, 7) AS bucket_order
        FROM (
          SELECT
            e.visitor_id,
            dateDiff('day', min(e.timestamp), min(ec.purchase_at)) AS days
          FROM events AS e
          INNER JOIN (
            SELECT visitor_id, min(timestamp) AS purchase_at
            FROM ecommerce_events
            WHERE site_id = #{ClickHouse.param(site.id)}
              #{ecommerce_source_filter(site)}
              AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
              AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
            GROUP BY visitor_id
          ) AS ec ON e.visitor_id = ec.visitor_id
          WHERE e.site_id = #{ClickHouse.param(site.id)}
            AND e.event_type = 'pageview' AND e.ip_is_bot = 0
            AND e.click_id != ''
            AND e.timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND e.timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          GROUP BY e.visitor_id
        )
      )
      GROUP BY bucket, bucket_order
      ORDER BY bucket_order
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Top page paths for ad visitor sessions with conversion rates."
  def ad_visitor_paths(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      # Flat query: build paths from events with click_id, check purchaser status inline
      sql = """
      SELECT
        journey,
        count() AS visitors,
        countIf(is_purchaser = 1) AS converters,
        round(countIf(is_purchaser = 1) / greatest(count(), 1) * 100, 1) AS conversion_rate
      FROM (
        SELECT
          session_id,
          any(visitor_id) AS vid,
          arrayStringConcat(
            arraySlice(
              arrayMap(x -> x.2, arraySort(x -> x.1, arrayZip(groupArray(timestamp), groupArray(url_path)))),
              1, 5
            ),
            ' → '
          ) AS journey,
          max(visitor_id IN (
            SELECT DISTINCT visitor_id FROM ecommerce_events
            WHERE site_id = #{ClickHouse.param(site.id)}
              #{ecommerce_source_filter(site)}
              AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
              AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          )) AS is_purchaser
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND click_id != ''
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY session_id
      )
      GROUP BY journey
      ORDER BY visitors DESC
      LIMIT 20
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Top landing pages where ad visitors bounced (single-pageview sessions)."
  def ad_bounce_pages(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT landing_page, platform, count() AS bounces
      FROM (
        SELECT
          any(url_path) AS landing_page,
          any(click_id_type) AS platform
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND click_id != ''
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY session_id
        HAVING count() = 1
      )
      GROUP BY landing_page, platform
      ORDER BY bounces DESC
      LIMIT 20
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Daily time series of organic visitors, direct visitors, and total ad spend."
  def organic_lift_timeseries(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      ref = clean_referrer_sql(site)

      sql = """
      WITH daily_visitors AS (
        SELECT
          toDate(timestamp) AS date,
          uniqExactIf(visitor_id, #{ref} != '' AND click_id = '' AND utm_source = '') AS organic_visitors,
          uniqExactIf(visitor_id, #{ref} = '' AND click_id = '') AS direct_visitors
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY date
      ),
      daily_spend AS (
        SELECT
          date,
          sum(spend) AS total_spend
        FROM ad_spend FINAL
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND date >= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.from)))}
          AND date <= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.to)))}
        GROUP BY date
      )
      SELECT
        dv.date AS day,
        dv.organic_visitors,
        dv.direct_visitors,
        coalesce(ds.total_spend, 0) AS ad_spend
      FROM daily_visitors AS dv
      LEFT JOIN daily_spend AS ds ON dv.date = ds.date
      ORDER BY dv.date
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Compare organic/direct visitors on high-spend vs low-spend days."
  def organic_lift_comparison(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      ref = clean_referrer_sql(site)

      sql = """
      WITH daily_spend AS (
        SELECT
          date,
          sum(spend) AS total_spend
        FROM ad_spend FINAL
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND date >= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.from)))}
          AND date <= #{ClickHouse.param(Date.to_iso8601(DateTime.to_date(date_range.to)))}
        GROUP BY date
      ),
      median_spend AS (
        SELECT median(total_spend) AS med FROM daily_spend
      ),
      daily_visitors AS (
        SELECT
          toDate(timestamp) AS date,
          uniqExactIf(visitor_id, #{ref} != '' AND click_id = '' AND utm_source = '') AS organic_visitors,
          uniqExactIf(visitor_id, #{ref} = '' AND click_id = '') AS direct_visitors
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY date
      )
      SELECT
        if(ds.total_spend >= ms.med, 'high_spend', 'low_spend') AS period_type,
        count() AS days,
        round(avg(ds.total_spend), 2) AS avg_daily_spend,
        round(avg(dv.organic_visitors), 1) AS avg_organic_visitors,
        round(avg(dv.direct_visitors), 1) AS avg_direct_visitors
      FROM daily_visitors AS dv
      INNER JOIN daily_spend AS ds ON dv.date = ds.date
      CROSS JOIN median_spend AS ms
      GROUP BY period_type
      ORDER BY spend_group
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Visitor quality metrics per ad platform/campaign with composite quality score."
  def visitor_quality_by_source(%Site{} = site, %User{} = user, date_range, opts \\ []) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      {group_col, result_col} =
        if opts[:group_by] == "campaign",
          do: {"if(utm_campaign != '', utm_campaign, '(none)')", "campaign"},
          else: {"click_id_type", "platform"}

      # Three-level: session → visitor → group
      # Inner: per-session metrics (needed for accurate bounce = 1 pageview)
      # Middle: per-visitor aggregates (needed for return rate = sessions > 1)
      # Outer: per-group aggregates
      sql = """
      SELECT
        #{result_col},
        count() AS visitors,
        round(sum(pageviews) / greatest(sum(sessions), 1), 1) AS avg_pages,
        round(avg(coalesce(avg_dur, 0)), 0) AS avg_duration_s,
        round(sum(bounced) / greatest(sum(sessions), 1) * 100, 1) AS bounce_rate,
        round(countIf(sessions > 1) / greatest(count(), 1) * 100, 1) AS return_rate,
        round(sum(high_intent_pvs) / greatest(sum(pageviews), 1) * 100, 1) AS high_intent_pct,
        round(
          least(sum(pageviews) / greatest(sum(sessions), 1) / 5, 1) * 25
          + least(avg(coalesce(avg_dur, 0)) / 300, 1) * 25
          + (1 - sum(bounced) / greatest(sum(sessions), 1)) * 20
          + countIf(sessions > 1) / greatest(count(), 1) * 15
          + sum(high_intent_pvs) / greatest(sum(pageviews), 1) * 15
        , 1) AS quality_score
      FROM (
        SELECT
          visitor_id,
          #{result_col},
          count() AS sessions,
          sum(pv) AS pageviews,
          avg(dur) AS avg_dur,
          sumIf(1, pv = 1) AS bounced,
          sum(hi) AS high_intent_pvs
        FROM (
          SELECT
            visitor_id,
            session_id,
            #{group_col} AS #{result_col},
            countIf(event_type = 'pageview') AS pv,
            avgIf(duration_s, event_type = 'duration' AND duration_s > 0) AS dur,
            countIf(visitor_intent NOT IN ('', 'browsing', 'bot') AND event_type = 'pageview') AS hi
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND ip_is_bot = 0
            AND click_id != ''
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          GROUP BY visitor_id, session_id, #{group_col}
        )
        GROUP BY visitor_id, #{result_col}
      )
      GROUP BY #{result_col}
      HAVING count() > 0
      ORDER BY visitors DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Revenue summary by channel type (Direct, Organic, Paid, Social, Referral, Email)."
  def revenue_by_channel(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      ref = clean_referrer_sql(site)

      # Only attribute from events with a real signal — exclude internal navigations
      # that evaluate to "Direct" after self-referral cleaning
      has_signal =
        "(#{ref} != '' OR utm_source != '' OR utm_medium != '' OR utm_campaign != '' OR click_id != '')"

      channel_expr = """
      multiIf(
              utm_medium IN ('cpc', 'ppc', 'paid', 'paidsearch', 'cpm'), 'Paid',
              utm_medium = 'email' OR #{ref} IN ('mail.google.com', 'mail.yahoo.com', 'outlook.live.com'), 'Email',
              #{ref} IN ('google.com', 'bing.com', 'duckduckgo.com', 'yahoo.com', 'baidu.com'), 'Organic Search',
              #{ref} IN ('facebook.com', 'instagram.com', 'twitter.com', 'linkedin.com', 'pinterest.com', 'tiktok.com', 'reddit.com', 't.co'), 'Social',
              #{ref} != '', 'Referral',
              'Direct'
            )
      """

      sql = """
      SELECT
        channel,
        uniq(e.visitor_id) AS visitors,
        countDistinct(ec.order_id) AS orders,
        sum(ec.revenue) AS total_revenue,
        round(countDistinct(ec.order_id) / greatest(uniq(e.visitor_id), 1) * 100, 2) AS conversion_rate
      FROM (
        SELECT
          visitor_id,
          argMin(#{channel_expr}, timestamp) AS channel
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND #{has_signal}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY visitor_id
      ) AS e
      LEFT JOIN (
        SELECT visitor_id, order_id, revenue
        FROM ecommerce_events
        WHERE site_id = #{ClickHouse.param(site.id)}
          #{ecommerce_source_filter(site)}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      ) AS ec ON e.visitor_id = ec.visitor_id
      GROUP BY channel
      ORDER BY total_revenue DESC
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Daily revenue by source (top 5) for sparkline trends."
  def revenue_trend_by_source(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        source,
        toDate(ec.timestamp) AS day,
        sum(ec.revenue) AS revenue
      FROM (
        SELECT visitor_id, argMin(
          if(referrer_domain != '', referrer_domain, if(utm_source != '', utm_source, 'Direct')),
          timestamp
        ) AS source
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND event_type = 'pageview' AND ip_is_bot = 0
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY visitor_id
      ) AS e
      INNER JOIN (
        SELECT visitor_id, revenue, timestamp
        FROM ecommerce_events
        WHERE site_id = #{ClickHouse.param(site.id)}
          #{ecommerce_source_filter(site)}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      ) AS ec ON e.visitor_id = ec.visitor_id
      WHERE source IN (
        SELECT source FROM (
          SELECT argMin(
            if(referrer_domain != '', referrer_domain, if(utm_source != '', utm_source, 'Direct')),
            timestamp
          ) AS source, sum(revenue) AS rev
          FROM events AS e2
          INNER JOIN ecommerce_events AS ec2 ON e2.visitor_id = ec2.visitor_id
            AND ec2.site_id = #{ClickHouse.param(site.id)}
            #{ecommerce_source_filter(site)}
          WHERE e2.site_id = #{ClickHouse.param(site.id)}
            AND e2.event_type = 'pageview' AND e2.ip_is_bot = 0
            AND e2.timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND e2.timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
          GROUP BY e2.visitor_id
          ORDER BY rev DESC LIMIT 5
        )
      )
      GROUP BY source, day
      ORDER BY source, day
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Revenue cohorts: group customers by first-purchase week, track revenue over time."
  def cohort_revenue(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        toMonday(first_purchase) AS cohort_week,
        intDiv(dateDiff('day', first_purchase, toDate(e.timestamp)), 7) AS week_number,
        uniq(e.visitor_id) AS customers,
        sum(e.revenue) AS revenue,
        round(sum(e.revenue) / greatest(uniq(e.visitor_id), 1), 2) AS revenue_per_customer
      FROM ecommerce_events AS e
      INNER JOIN (
        SELECT visitor_id, min(toDate(timestamp)) AS first_purchase
        FROM ecommerce_events
        WHERE site_id = #{ClickHouse.param(site.id)}
          #{ecommerce_source_filter(site)}
        GROUP BY visitor_id
      ) AS fp ON e.visitor_id = fp.visitor_id
      WHERE e.site_id = #{ClickHouse.param(site.id)}
        #{ecommerce_source_filter(site)}
        AND e.timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND e.timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      GROUP BY cohort_week, week_number
      ORDER BY cohort_week, week_number
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Buyer vs non-buyer page visit patterns (lift analysis)."
  def buyer_page_patterns(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        e.url_path,
        uniqIf(e.visitor_id, is_buyer = 1) AS buyer_visitors,
        uniqIf(e.visitor_id, is_buyer = 0) AS nonbuyer_visitors,
        countIf(is_buyer = 1) AS buyer_pageviews,
        countIf(is_buyer = 0) AS nonbuyer_pageviews,
        round(uniqIf(e.visitor_id, is_buyer = 1) / greatest(uniqIf(e.visitor_id, is_buyer = 0), 1), 3) AS lift
      FROM (
        SELECT
          events.visitor_id,
          events.url_path,
          if(ec.visitor_id != '', 1, 0) AS is_buyer
        FROM events
        LEFT JOIN (
          SELECT DISTINCT visitor_id
          FROM ecommerce_events
          WHERE site_id = #{ClickHouse.param(site.id)}
            #{ecommerce_source_filter(site)}
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        ) AS ec ON events.visitor_id = ec.visitor_id
        WHERE events.site_id = #{ClickHouse.param(site.id)}
          AND events.event_type = 'pageview' AND events.ip_is_bot = 0
          AND events.timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND events.timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      ) AS e
      GROUP BY e.url_path
      HAVING buyer_visitors >= 2
      ORDER BY lift DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Behavioral summary: avg sessions/pages/duration for buyers vs non-buyers."
  def buyer_vs_nonbuyer_stats(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        is_buyer,
        round(avg(sessions), 1) AS avg_sessions,
        round(avg(pages), 1) AS avg_pages,
        round(avg(total_duration), 0) AS avg_duration
      FROM (
        SELECT
          events.visitor_id,
          if(ec.visitor_id != '', 1, 0) AS is_buyer,
          uniq(events.session_id) AS sessions,
          countIf(events.event_type = 'pageview') AS pages,
          sum(events.duration_s) AS total_duration
        FROM events
        LEFT JOIN (
          SELECT DISTINCT visitor_id
          FROM ecommerce_events
          WHERE site_id = #{ClickHouse.param(site.id)}
            #{ecommerce_source_filter(site)}
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        ) AS ec ON events.visitor_id = ec.visitor_id
        WHERE events.site_id = #{ClickHouse.param(site.id)}
          AND events.ip_is_bot = 0
          AND events.timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND events.timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY events.visitor_id, is_buyer
      )
      GROUP BY is_buyer
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Churn risk: customers with declining engagement (recent vs prior 14-day window)."
  def churn_risk_visitors(%Site{} = site, %User{} = user) do
    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        visitor_id,
        recent_sessions,
        prior_sessions,
        recent_pages,
        prior_pages,
        round((prior_sessions - recent_sessions) / greatest(prior_sessions, 1) * 100, 1) AS session_decline_pct,
        round((prior_pages - recent_pages) / greatest(prior_pages, 1) * 100, 1) AS pages_decline_pct,
        max_recent_ts
      FROM (
        SELECT
          visitor_id,
          countIf(timestamp >= now() - INTERVAL 14 DAY) AS recent_sessions,
          countIf(timestamp >= now() - INTERVAL 28 DAY AND timestamp < now() - INTERVAL 14 DAY) AS prior_sessions,
          sumIf(1, event_type = 'pageview' AND timestamp >= now() - INTERVAL 14 DAY) AS recent_pages,
          sumIf(1, event_type = 'pageview' AND timestamp >= now() - INTERVAL 28 DAY AND timestamp < now() - INTERVAL 14 DAY) AS prior_pages,
          max(timestamp) AS max_recent_ts
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND timestamp >= now() - INTERVAL 28 DAY
          AND ip_is_bot = 0
          AND visitor_id IN (
            SELECT DISTINCT visitor_id
            FROM ecommerce_events
            WHERE site_id = #{ClickHouse.param(site.id)}
              #{ecommerce_source_filter(site)}
          )
        GROUP BY visitor_id
        HAVING prior_sessions >= 2
      )
      WHERE recent_sessions < prior_sessions * 0.5
         OR recent_pages < prior_pages * 0.3
      ORDER BY session_decline_pct DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Look up ecommerce totals for a list of visitor IDs. Returns map of visitor_id => %{orders, revenue}."
  def ecommerce_for_visitors(%Site{} = site, visitor_ids) when is_list(visitor_ids) do
    visitor_ids = Enum.reject(visitor_ids, &(&1 == "" or is_nil(&1)))

    if visitor_ids == [] or not site.ecommerce_enabled do
      {:ok, %{}}
    else
      id_list = Enum.map_join(visitor_ids, ", ", &ClickHouse.param/1)

      sql = """
      SELECT
        visitor_id,
        count() AS orders,
        sum(revenue) AS revenue
      FROM ecommerce_events
      WHERE site_id = #{ClickHouse.param(site.id)}
        #{ecommerce_source_filter(site)}
        AND visitor_id IN (#{id_list})
      GROUP BY visitor_id
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          map =
            Map.new(rows, fn row ->
              {row["visitor_id"], %{orders: to_int(row["orders"]), revenue: row["revenue"]}}
            end)

          {:ok, map}

        _ ->
          {:ok, %{}}
      end
    end
  end

  @doc "Get visitor_ids who reached funnel step N but NOT step N+1."
  def funnel_abandoned_at_step(%Site{} = site, %User{} = user, funnel, target_step) do
    date_range = ensure_date_range(:month)
    steps = funnel.steps || []

    with :ok <- authorize(site, user) do
      step_conditions = build_funnel_conditions(steps)

      sql = """
      SELECT visitor_id
      FROM (
        SELECT visitor_id, windowFunnel(86400)(timestamp, #{step_conditions}) AS level
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        GROUP BY visitor_id
      )
      WHERE level = #{ClickHouse.param(target_step)}
      LIMIT 1000
      """

      case ClickHouse.query(sql) do
        {:ok, rows} -> {:ok, Enum.map(rows, & &1["visitor_id"])}
        error -> error
      end
    end
  end

  defp build_funnel_conditions(steps) do
    steps
    |> Enum.map(fn step ->
      type = step["type"] || Map.get(step, :type, "pageview")
      value = step["value"] || Map.get(step, :value, "")

      case type do
        "pageview" -> "event_type = 'pageview' AND url_path = #{ClickHouse.param(value)}"
        "custom_event" -> "event_type = 'custom' AND event_name = #{ClickHouse.param(value)}"
        _ -> "1=0"
      end
    end)
    |> Enum.join(", ")
  end

  @doc """
  Funnel stats using ClickHouse windowFunnel().
  Steps is a list of event conditions (e.g., event_type/url_path matches).
  """
  def funnel_stats(%Site{} = site, %User{} = user, %{steps: steps} = _funnel, date_range \\ "30d")
      when is_list(steps) do
    date_range = ensure_date_range(date_range)

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
          AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
          AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
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
        # Get total unique visitors for conversion rate calculation
        total_visitors =
          case ClickHouse.query("""
                 SELECT uniq(visitor_id) AS total
                 FROM events
                 WHERE site_id = #{ClickHouse.param(site.id)}
                   AND event_type = 'pageview' AND ip_is_bot = 0
                   AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
                   AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
               """) do
            {:ok, [%{"total" => t}]} -> to_int(t)
            _ -> 0
          end

        # Batch all goals into a single query with UNION ALL
        unions =
          goals
          |> Enum.map(fn goal ->
            condition = goal_condition(goal)

            """
            SELECT #{ClickHouse.param(to_string(goal.id))} AS goal_id,
              count() AS completions,
              uniq(visitor_id) AS unique_completers
            FROM events
            WHERE site_id = #{ClickHouse.param(site.id)}
              AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
              AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
              AND ip_is_bot = 0
              AND #{condition}
            """
          end)
          |> Enum.join("\nUNION ALL\n")

        counts =
          case ClickHouse.query(unions) do
            {:ok, rows} ->
              Map.new(rows, fn r ->
                {r["goal_id"],
                 %{
                   completions: to_int(r["completions"]),
                   unique_completers: to_int(r["unique_completers"])
                 }}
              end)

            _ ->
              %{}
          end

        results =
          Enum.map(goals, fn goal ->
            stats = Map.get(counts, to_string(goal.id), %{completions: 0, unique_completers: 0})

            conv_rate =
              if total_visitors > 0,
                do: Float.round(stats.unique_completers / total_visitors * 100, 2),
                else: 0.0

            %{
              goal_id: goal.id,
              name: goal.name,
              goal_type: goal.goal_type,
              completions: stats.completions,
              unique_completers: stats.unique_completers,
              conversion_rate: conv_rate
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
        #{ecommerce_source_filter(site)}
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

  def ecommerce_top_products(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      site_currency = site.currency || "USD"

      sql = """
      SELECT
        JSONExtractString(item, 'name') AS name,
        JSONExtractString(item, 'category') AS category,
        sum(toUInt32OrZero(JSONExtractString(item, 'quantity'))) AS quantity,
        sum(toDecimal64OrZero(JSONExtractString(item, 'price'), 2) *
            toUInt32OrZero(JSONExtractString(item, 'quantity'))) AS revenue
      FROM ecommerce_events
      ARRAY JOIN JSONExtractArrayRaw(items) AS item
      WHERE site_id = #{ClickHouse.param(site.id)}
        #{ecommerce_source_filter(site)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND (currency = #{ClickHouse.param(site_currency)} OR currency = '')
        AND name != ''
      GROUP BY name, category
      ORDER BY revenue DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  def ecommerce_orders(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      site_currency = site.currency || "USD"
      tz = tz_sql(site)

      sql = """
      SELECT
        order_id,
        visitor_id,
        revenue,
        subtotal,
        tax,
        shipping,
        discount,
        currency,
        items,
        toTimezone(timestamp, #{tz}) AS timestamp
      FROM ecommerce_events
      WHERE site_id = #{ClickHouse.param(site.id)}
        #{ecommerce_source_filter(site)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND (currency = #{ClickHouse.param(site_currency)} OR currency = '')
      ORDER BY timestamp DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Revenue timeseries for ecommerce chart — bucketed by day."
  def ecommerce_timeseries(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      site_currency = site.currency || "USD"
      tz = tz_sql(site)

      sql = """
      SELECT
        toDate(toTimezone(timestamp, #{tz})) AS day,
        count() AS orders,
        sum(revenue) AS revenue
      FROM ecommerce_events
      WHERE site_id = #{ClickHouse.param(site.id)}
        #{ecommerce_source_filter(site)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND (currency = #{ClickHouse.param(site_currency)} OR currency = '')
      GROUP BY day
      ORDER BY day
      """

      ClickHouse.query(sql)
    end
  end

  @doc "Count of unique visitors who have been identified (have email in Postgres)."
  def identified_visitors_count(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      vid_sql = """
      SELECT DISTINCT visitor_id
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND event_type = 'pageview'
        AND ip_is_bot = 0
      """

      case ClickHouse.query(vid_sql) do
        {:ok, rows} ->
          visitor_ids = Enum.map(rows, & &1["visitor_id"]) |> Enum.uniq()
          # Check how many have emails in Postgres
          count = Spectabas.Visitors.count_identified(site.id, visitor_ids)
          {:ok, count}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Ecommerce orders for a specific visitor."
  def visitor_orders(%Site{} = site, visitor_id) when is_binary(visitor_id) do
    tz = tz_sql(site)

    sql = """
    SELECT order_id, revenue, subtotal, tax, shipping, discount, currency, items,
      toTimezone(timestamp, #{tz}) AS timestamp
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site.id)}
      #{ecommerce_source_filter(site)}
      AND visitor_id = #{ClickHouse.param(visitor_id)}
    ORDER BY timestamp DESC
    LIMIT 50
    """

    ClickHouse.query(sql)
  end

  @doc "Calculate lifetime value for a visitor from ecommerce events."
  def visitor_ltv(%Site{} = site, visitor_id) do
    sql = """
    SELECT
      sum(revenue) - sum(refund_amount) AS net_revenue,
      sum(revenue) AS gross_revenue,
      sum(refund_amount) AS total_refunds,
      countDistinct(order_id) AS total_orders,
      min(timestamp) AS first_purchase,
      max(timestamp) AS last_purchase
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site.id)}
      #{ecommerce_source_filter(site)}
      AND visitor_id = #{ClickHouse.param(visitor_id)}
      AND visitor_id != ''
    """

    ClickHouse.query(sql)
  end

  @doc """
  All events for a specific visitor_id, ordered by timestamp.
  """
  def visitor_timeline(%Site{} = site, visitor_id) when is_binary(visitor_id) do
    tz = tz_sql(site)

    sql = """
    SELECT
      event_type, event_name, url_path, url_host, referrer_domain, referrer_url,
      utm_source, utm_medium, utm_campaign,
      device_type, browser, browser_version, os, os_version,
      screen_width, screen_height, duration_s,
      ip_address, ip_country, ip_country_name, ip_region_name, ip_city,
      ip_timezone, ip_org, ip_is_datacenter, ip_is_vpn, ip_is_tor, ip_is_bot,
      session_id, visitor_intent, user_agent, toTimezone(timestamp, #{tz}) AS timestamp
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
    tz = tz_sql(site)

    sql = """
    SELECT
      toTimezone(min(timestamp), #{tz}) AS first_seen,
      toTimezone(max(timestamp), #{tz}) AS last_seen,
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
      groupUniqArrayIf(5)(utm_source, utm_source != '') AS utm_sources,
      groupUniqArrayIf(5)(utm_medium, utm_medium != '') AS utm_mediums,
      groupUniqArrayIf(5)(utm_campaign, utm_campaign != '') AS utm_campaigns,
      groupUniqArrayIf(5)(utm_term, utm_term != '') AS utm_terms,
      groupUniqArrayIf(5)(utm_content, utm_content != '') AS utm_contents,
      argMinIf(click_id, timestamp, click_id != '') AS first_click_id,
      argMinIf(click_id_type, timestamp, click_id != '') AS first_click_id_type,
      groupUniqArrayIf(3)(click_id_type, click_id_type != '') AS click_id_platforms
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
  All IP addresses used by a specific visitor, with first/last seen and event counts.
  """
  def visitor_ips(%Site{} = site, visitor_id) when is_binary(visitor_id) do
    tz = tz_sql(site)

    sql = """
    SELECT
      ip_address,
      toTimezone(min(timestamp), #{tz}) AS first_seen,
      toTimezone(max(timestamp), #{tz}) AS last_seen,
      count() AS events,
      any(ip_country) AS country,
      any(ip_city) AS city,
      any(ip_org) AS org,
      any(ip_is_datacenter) AS is_datacenter,
      any(ip_is_vpn) AS is_vpn
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND visitor_id = #{ClickHouse.param(visitor_id)}
      AND ip_address != ''
    GROUP BY ip_address
    ORDER BY last_seen DESC
    LIMIT 50
    """

    ClickHouse.query(sql)
  end

  @doc """
  Find other visitors who share the same IP address.
  """
  def visitors_by_ip(%Site{} = site, ip_address)
      when is_binary(ip_address) and ip_address != "" do
    tz = tz_sql(site)

    sql = """
    SELECT
      visitor_id,
      toTimezone(min(timestamp), #{tz}) AS first_seen,
      toTimezone(max(timestamp), #{tz}) AS last_seen,
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
  Top pages visited from a specific IP address.
  """
  def ip_page_hits(%Site{} = site, ip_address)
      when is_binary(ip_address) and ip_address != "" do
    sql = """
    SELECT
      url_path,
      count() AS hits
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND ip_address = #{ClickHouse.param(ip_address)}
      AND event_type = 'pageview'
    GROUP BY url_path
    ORDER BY hits DESC
    LIMIT 20
    """

    ClickHouse.query(sql)
  end

  def ip_page_hits(_, _), do: {:ok, []}

  @doc """
  Find other visitors who share the same browser fingerprint.
  Useful for detecting alt accounts, ban evasion, and fraud.
  """
  def visitors_by_fingerprint(%Site{} = site, fingerprint)
      when is_binary(fingerprint) and fingerprint != "" do
    tz = tz_sql(site)

    sql = """
    SELECT
      visitor_id,
      toTimezone(min(timestamp), #{tz}) AS first_seen,
      toTimezone(max(timestamp), #{tz}) AS last_seen,
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
        AND ip_is_bot = 0
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
    per_page = opts |> Keyword.get(:per_page, 50) |> min(200) |> max(1)
    cursor = Keyword.get(opts, :cursor, nil)

    cursor_clause =
      case cursor do
        %{"last_seen" => ts, "visitor_id" => vid} when is_binary(ts) and is_binary(vid) ->
          "HAVING (last_seen, visitor_id) < (#{ClickHouse.param(ts)}, #{ClickHouse.param(vid)})"

        _ ->
          ""
      end

    with :ok <- authorize(site, user) do
      tz = tz_sql(site)

      sql = """
      SELECT
        visitor_id,
        toTimezone(min(timestamp), #{tz}) AS first_seen,
        toTimezone(max(timestamp), #{tz}) AS last_seen,
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
        AND ip_is_bot = 0
        #{seg}
      GROUP BY visitor_id
      #{cursor_clause}
      ORDER BY last_seen DESC
      LIMIT #{ClickHouse.param(per_page)}
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          next_cursor =
            case List.last(rows) do
              nil ->
                nil

              last_row ->
                %{"last_seen" => last_row["last_seen"], "visitor_id" => last_row["visitor_id"]}
            end

          {:ok, rows, next_cursor}

        error ->
          error
      end
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
        AND ip_is_bot = 0
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
        AND ip_is_bot = 0
        AND JSONExtractString(properties, '_search_query') != ''
      GROUP BY search_term
      ORDER BY searches DESC
      LIMIT 100
      """

      ClickHouse.query(sql)
    end
  end

  # ---- Outbound Links ----

  @doc "Outbound links clicked by visitors, grouped by domain."
  def outbound_links(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        JSONExtractString(properties, 'domain') AS domain,
        JSONExtractString(properties, 'url') AS url,
        count() AS hits,
        uniq(visitor_id) AS visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'custom'
        AND event_name = '_outbound'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
      GROUP BY domain, url
      ORDER BY hits DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  # ---- File Downloads ----

  @doc "File downloads tracked automatically, grouped by filename."
  def file_downloads(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        JSONExtractString(properties, 'filename') AS filename,
        JSONExtractString(properties, 'url') AS url,
        count() AS hits,
        uniq(visitor_id) AS visitors
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'custom'
        AND event_name = '_download'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
      GROUP BY filename, url
      ORDER BY hits DESC
      LIMIT 50
      """

      ClickHouse.query(sql)
    end
  end

  # ---- Custom Events ----

  @doc "Custom events (excluding internal _ prefixed events), grouped by event name."
  def custom_events(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        event_name,
        count() AS hits,
        uniq(visitor_id) AS visitors,
        uniq(session_id) AS sessions,
        round(count() / greatest(uniq(visitor_id), 1), 1) AS avg_per_visitor
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'custom'
        AND event_name NOT LIKE '\\_%'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
        AND ip_is_bot = 0
      GROUP BY event_name
      ORDER BY hits DESC
      LIMIT 50
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
        SELECT cohort_week, count() AS cohort_size
        FROM (
          SELECT
            visitor_id,
            toMonday(min(toDate(timestamp))) AS cohort_week
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
            AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
            AND event_type = 'pageview'
            AND ip_is_bot = 0
          GROUP BY visitor_id
        )
        GROUP BY cohort_week
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
      # Median page_load per URL from _rum events, ordered by sample count
      # so we return data for the most-visited pages (matching top_pages).
      # Cap at 60000ms to filter corrupt data from old NaN bug.
      sql = """
      SELECT
        url_path,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0
          AND toFloat64OrZero(JSONExtractString(properties, 'page_load')) <= 60000)) AS page_load,
        count() AS samples
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_name = '_rum'
        AND timestamp >= #{ClickHouse.param(format_datetime(date_range.from))}
        AND timestamp <= #{ClickHouse.param(format_datetime(date_range.to))}
      GROUP BY url_path
      HAVING page_load > 0
      ORDER BY samples DESC
      LIMIT 100
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
  Returns a SQL WHERE fragment that filters ecommerce_events by source.
  If the site has an active Stripe integration, only show Stripe data (pi_*).
  Otherwise, show all data (API + JS tracker).
  """
  def ecommerce_source_filter(%Site{id: site_id}) do
    # Cache per-request in process dictionary to avoid repeated Repo.exists? calls
    # (this function is called 23+ times per ecommerce page load).
    cache_key = {:ecommerce_source_filter, site_id}

    case Process.get(cache_key) do
      nil ->
        # If the site has any payment provider integration, filter to only that provider's data.
        # Stripe uses pi_* order IDs, Braintree uses its own transaction IDs.
        # This prevents double-counting when both API and provider data exist.
        has_stripe =
          Spectabas.Repo.exists?(
            from(a in Spectabas.AdIntegrations.AdIntegration,
              where: a.site_id == ^site_id and a.platform == "stripe"
            )
          )

        has_braintree =
          Spectabas.Repo.exists?(
            from(a in Spectabas.AdIntegrations.AdIntegration,
              where: a.site_id == ^site_id and a.platform == "braintree"
            )
          )

        result =
          cond do
            has_stripe and has_braintree ->
              "AND (order_id LIKE 'pi_%' OR import_source = 'braintree')"

            has_stripe ->
              "AND order_id LIKE 'pi_%'"

            has_braintree ->
              "AND import_source = 'braintree'"

            true ->
              ""
          end

        Process.put(cache_key, result)
        result

      cached ->
        cached
    end
  end

  # ClickHouse toTimezone() snippet for converting UTC timestamps to site timezone
  defp tz_sql(%Site{} = site), do: ClickHouse.param(site.timezone || "UTC")

  # SQL expression that strips self-referrals from referrer_domain.
  # Returns the referrer_domain if it's not the site itself, empty string otherwise.
  # Covers: analytics subdomain (b.example.com), parent (example.com), www.parent
  defp clean_referrer_sql(%Site{} = site) do
    domain = site.domain || ""
    parent = parent_domain(domain)

    domains =
      [domain, parent, "www.#{parent}"]
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&ClickHouse.param/1)

    case domains do
      [] -> "referrer_domain"
      list -> "if(referrer_domain NOT IN (#{Enum.join(list, ", ")}), referrer_domain, '')"
    end
  end

  defp parent_domain(domain) do
    parts = String.split(domain, ".")
    if length(parts) > 2, do: parts |> Enum.drop(1) |> Enum.join("."), else: domain
  end

  # Generic import-aware query: runs native query on native range, import query on
  # import range, merges results by key. Returns {:ok, merged_rows} or {:error, reason}.
  # - native_query_fn: fn(native_date_range) -> SQL string
  # - import_query_fn: fn(import_date_range) -> SQL string (or nil to skip)
  # - key_fn: fn(row) -> merge key (string or tuple)
  # - merge_fn: fn(rows_with_same_key) -> single merged row
  defp import_aware_query(site, date_range, native_query_fn, import_query_fn, key_fn, merge_fn) do
    {native_range, import_range} = split_date_range(site, date_range)

    native_rows =
      if native_range do
        case ClickHouse.query(native_query_fn.(native_range)) do
          {:ok, rows} -> rows
          _ -> []
        end
      else
        []
      end

    imported_rows =
      if import_range && import_query_fn do
        case ClickHouse.query(import_query_fn.(import_range)) do
          {:ok, rows} -> rows
          _ -> []
        end
      else
        []
      end

    merged =
      (native_rows ++ imported_rows)
      |> Enum.group_by(key_fn)
      |> Enum.map(fn {_key, rows} -> merge_fn.(rows) end)

    {:ok, merged}
  end

  # Sum numeric string fields across multiple rows
  defp sum_field(rows, field) do
    Enum.reduce(rows, 0, fn row, acc -> acc + to_int(row[field]) end)
  end

  # Split a date range into native and imported portions based on site's import dates.
  # Returns {native_range | nil, import_range | nil} where each is %{from: Date, to: Date}.
  defp split_date_range(%Site{native_start_date: nil}, date_range), do: {date_range, nil}
  defp split_date_range(%Site{import_end_date: nil}, date_range), do: {date_range, nil}

  defp split_date_range(%Site{} = site, date_range) do
    from_date = DateTime.to_date(date_range.from)
    to_date = DateTime.to_date(date_range.to)

    cond do
      # Entirely after import period — native only
      Date.compare(from_date, site.native_start_date) != :lt ->
        {date_range, nil}

      # Entirely within import period — import only
      Date.compare(to_date, site.import_end_date) != :gt ->
        {nil, %{from: from_date, to: to_date}}

      # Spans both — split at the boundary
      true ->
        import_part = %{from: from_date, to: site.import_end_date}

        native_from =
          DateTime.new!(site.native_start_date, ~T[00:00:00], "Etc/UTC")

        native_part = %{from: native_from, to: date_range.to}
        {native_part, import_part}
    end
  end

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
      round(countIf(pv = 1) / greatest(count(), 1) * 100, 1) AS bounce_rate,
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
        AND ip_is_bot = 0
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

  @doc """
  Row-level timeseries: pageviews and visitors for a specific dimension value over time.
  Used for sparkline charts when clicking a table row.
  """
  def row_timeseries(%Site{} = site, %User{} = user, date_range, field, value) do
    date_range = ensure_date_range(date_range)

    allowed_fields =
      ~w(url_path referrer_domain ip_country ip_region_name browser os device_type)

    unless field in allowed_fields do
      {:error, :invalid_field}
    else
      with :ok <- authorize(site, user),
           :ok <- check_clickhouse() do
        tz = site.timezone || "UTC"

        period =
          if Date.diff(DateTime.to_date(date_range.to), DateTime.to_date(date_range.from)) <= 2,
            do: :day,
            else: :week

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
          AND #{field} = #{ClickHouse.param(value)}
        GROUP BY bucket
        ORDER BY bucket ASC
        """

        ClickHouse.query(sql)
      end
    end
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
    |> Kernel.++(Spectabas.Analytics.SpamFilter.all_domains())
    |> Enum.uniq()
  end

  defp self_referrer_domains(_),
    do: ["www.spectabas.com", "spectabas.com"] ++ Spectabas.Analytics.SpamFilter.all_domains()
end
