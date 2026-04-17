defmodule Spectabas.Workers.DailyRollup do
  @moduledoc """
  Populates all daily rollup AggregatingMergeTree tables used by dashboard queries.

  Rollup tables:
  - daily_rollup (overall per-site-per-day)
  - daily_page_rollup (per URL path)
  - daily_source_rollup (per referrer domain)
  - daily_geo_rollup (per country/region/city/lat/lon/timezone)
  - daily_device_rollup (per device_type/browser/os)

  Modes:
  - no args → roll up yesterday (UTC), used by the daily cron
  - `%{"date" => "YYYY-MM-DD"}` → roll up a specific date (idempotent)
  - `%{"backfill" => true}` → one-time historical backfill of all complete days

  AggregatingMergeTree merges states on the same sort key:
  - uniqExactIfState merges via set union (naturally idempotent on exact dup)
  - countIfState merges via sum (NOT idempotent — re-running would double-count)
  So re-runs for the same date DELETE existing rows first (synchronous mutation).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.ClickHouse

  @rollup_tables ~w(daily_rollup daily_page_rollup daily_source_rollup daily_geo_rollup daily_device_rollup daily_campaign_rollup)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"backfill" => true}}) do
    Logger.notice("[DailyRollup] Historical backfill starting")

    results =
      Enum.map(@rollup_tables, fn table ->
        run(backfill_delete_sql(table), backfill_insert_sql(table), "backfill/#{table}")
      end)

    if Enum.any?(results, &match?({:error, _}, &1)), do: hd(results), else: :ok
  end

  def perform(%Oban.Job{args: %{"date" => date_str}}) do
    results =
      Enum.map(@rollup_tables, fn table ->
        run(
          date_delete_sql(table, date_str),
          date_insert_sql(table, date_str),
          "#{date_str}/#{table}"
        )
      end)

    if Enum.any?(results, &match?({:error, _}, &1)), do: hd(results), else: :ok
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    results =
      Enum.map(@rollup_tables, fn table ->
        run(
          date_delete_sql(table, yesterday),
          date_insert_sql(table, yesterday),
          "#{yesterday}/#{table}"
        )
      end)

    if Enum.any?(results, &match?({:error, _}, &1)), do: hd(results), else: :ok
  end

  defp run(delete_sql, insert_sql, label) do
    with :ok <- ClickHouse.execute(delete_sql),
         :ok <- ClickHouse.execute(insert_sql) do
      Logger.notice("[DailyRollup] #{label}")
      :ok
    else
      {:error, reason} ->
        Logger.error("[DailyRollup] Failed #{label}: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  # ---------------- SQL builders ----------------

  @doc false
  def date_delete_sql(table, date_str) when is_binary(date_str) do
    """
    ALTER TABLE #{sanitize(table)} DELETE
    WHERE date = #{ClickHouse.param(date_str)}
    SETTINGS mutations_sync = 2
    """
  end

  @doc false
  def backfill_delete_sql(table) do
    """
    ALTER TABLE #{sanitize(table)} DELETE
    WHERE date < today()
    SETTINGS mutations_sync = 2
    """
  end

  @doc false
  def date_insert_sql(table, date_str) when is_binary(date_str) do
    where_range = "toDate(timestamp) = #{ClickHouse.param(date_str)}"
    build_insert_sql(table, where_range)
  end

  @doc false
  def backfill_insert_sql(table) do
    build_insert_sql(table, "toDate(timestamp) < today()")
  end

  defp build_insert_sql("daily_rollup", where_range) do
    """
    INSERT INTO daily_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis_state,
      uniqExactIfState(session_id, event_type = 'pageview' AND ip_is_bot = 0) AS sess_state
    FROM events
    WHERE #{where_range}
    GROUP BY site_id, date
    """
  end

  defp build_insert_sql("daily_page_rollup", where_range) do
    """
    INSERT INTO daily_page_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      url_path,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis_state
    FROM events
    WHERE #{where_range} AND url_path != ''
    GROUP BY site_id, date, url_path
    SETTINGS max_memory_usage = 500000000, max_bytes_before_external_group_by = 250000000
    """
  end

  defp build_insert_sql("daily_source_rollup", where_range) do
    """
    INSERT INTO daily_source_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      referrer_domain,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(session_id, event_type = 'pageview' AND ip_is_bot = 0) AS sess_state
    FROM events
    WHERE #{where_range} AND referrer_domain != ''
    GROUP BY site_id, date, referrer_domain
    """
  end

  defp build_insert_sql("daily_geo_rollup", where_range) do
    """
    INSERT INTO daily_geo_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      ip_country,
      ip_region_name,
      ip_city,
      ip_lat,
      ip_lon,
      ip_timezone,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis_state
    FROM events
    WHERE #{where_range} AND ip_country != ''
    GROUP BY site_id, date, ip_country, ip_region_name, ip_city, ip_lat, ip_lon, ip_timezone
    SETTINGS max_memory_usage = 500000000, max_bytes_before_external_group_by = 250000000
    """
  end

  defp build_insert_sql("daily_device_rollup", where_range) do
    """
    INSERT INTO daily_device_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      device_type,
      browser,
      os,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis_state
    FROM events
    WHERE #{where_range} AND (device_type != '' OR browser != '' OR os != '')
    GROUP BY site_id, date, device_type, browser, os
    """
  end

  defp build_insert_sql("daily_campaign_rollup", where_range) do
    """
    INSERT INTO daily_campaign_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      utm_campaign,
      utm_source,
      utm_medium,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis_state,
      uniqExactIfState(session_id, event_type = 'pageview' AND ip_is_bot = 0) AS sess_state
    FROM events
    WHERE #{where_range} AND utm_campaign != ''
    GROUP BY site_id, date, utm_campaign, utm_source, utm_medium
    """
  end

  defp sanitize(t) when t in @rollup_tables, do: t
  defp sanitize(t), do: raise(ArgumentError, "Unknown rollup table: #{t}")
end
