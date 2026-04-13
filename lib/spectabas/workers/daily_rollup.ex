defmodule Spectabas.Workers.DailyRollup do
  @moduledoc """
  Populates the `daily_rollup` AggregatingMergeTree table used by timeseries_fast.

  Modes:
  - no args → roll up yesterday (UTC), used by the daily cron
  - `%{"date" => "YYYY-MM-DD"}` → roll up a specific date (idempotent)
  - `%{"backfill" => true}` → one-time historical backfill of all complete days

  AggregatingMergeTree merges states on the same (site_id, date) sort key:
  - uniqExactIfState merges via set union (naturally idempotent)
  - countIfState merges via sum (NOT idempotent — re-running would double-count)
  So re-runs for the same date DELETE existing rows first (synchronous mutation).
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.ClickHouse

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"backfill" => true}}) do
    run_sql_pair(backfill_delete_sql(), backfill_insert_sql(), "backfill")
  end

  def perform(%Oban.Job{args: %{"date" => date_str}}) do
    run_sql_pair(date_delete_sql(date_str), date_insert_sql(date_str), date_str)
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()
    run_sql_pair(date_delete_sql(yesterday), date_insert_sql(yesterday), yesterday)
  end

  defp run_sql_pair(delete_sql, insert_sql, label) do
    with :ok <- ClickHouse.execute(delete_sql),
         :ok <- ClickHouse.execute(insert_sql) do
      Logger.notice("[DailyRollup] Rolled up #{label}")
      :ok
    else
      {:error, reason} ->
        Logger.error("[DailyRollup] Failed for #{label}: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  @doc false
  def date_delete_sql(date_str) when is_binary(date_str) do
    """
    ALTER TABLE daily_rollup DELETE
    WHERE date = #{ClickHouse.param(date_str)}
    SETTINGS mutations_sync = 2
    """
  end

  @doc false
  def date_insert_sql(date_str) when is_binary(date_str) do
    d = ClickHouse.param(date_str)

    """
    INSERT INTO daily_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis_state,
      uniqExactIfState(session_id, event_type = 'pageview' AND ip_is_bot = 0) AS sess_state
    FROM events
    WHERE toDate(timestamp) = #{d}
    GROUP BY site_id, date
    """
  end

  @doc false
  def backfill_delete_sql do
    """
    ALTER TABLE daily_rollup DELETE
    WHERE date < today()
    SETTINGS mutations_sync = 2
    """
  end

  @doc false
  def backfill_insert_sql do
    """
    INSERT INTO daily_rollup
    SELECT
      site_id,
      toDate(timestamp) AS date,
      countIfState(event_type = 'pageview' AND ip_is_bot = 0) AS pv_state,
      uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis_state,
      uniqExactIfState(session_id, event_type = 'pageview' AND ip_is_bot = 0) AS sess_state
    FROM events
    WHERE toDate(timestamp) < today()
    GROUP BY site_id, date
    """
  end
end
