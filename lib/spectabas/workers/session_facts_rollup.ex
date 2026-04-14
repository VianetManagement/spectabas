defmodule Spectabas.Workers.SessionFactsRollup do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.ClickHouse

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"backfill" => true}}) do
    Logger.notice("[SessionFactsRollup] Historical backfill starting")

    with :ok <- delete_range("date < today()"),
         :ok <- insert_range("toDate(timestamp) < today()") do
      Logger.notice("[SessionFactsRollup] Historical backfill complete")
      :ok
    else
      {:error, reason} ->
        Logger.error("[SessionFactsRollup] Backfill failed: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  def perform(%Oban.Job{args: %{"date" => date_str}}) do
    with :ok <- delete_range("date = #{ClickHouse.param(date_str)}"),
         :ok <- insert_range("toDate(timestamp) = #{ClickHouse.param(date_str)}") do
      Logger.notice("[SessionFactsRollup] Rolled up #{date_str}")
      :ok
    else
      {:error, reason} ->
        Logger.error("[SessionFactsRollup] Failed #{date_str}: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    with :ok <- delete_range("date = #{ClickHouse.param(yesterday)}"),
         :ok <- insert_range("toDate(timestamp) = #{ClickHouse.param(yesterday)}") do
      Logger.notice("[SessionFactsRollup] Rolled up #{yesterday}")
      :ok
    else
      {:error, reason} ->
        Logger.error("[SessionFactsRollup] Failed #{yesterday}: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp delete_range(where_clause) do
    sql = """
    ALTER TABLE daily_session_facts DELETE
    WHERE #{where_clause}
    SETTINGS mutations_sync = 2
    """

    ClickHouse.execute(sql)
  end

  defp insert_range(where_clause) do
    sql = """
    INSERT INTO daily_session_facts
    SELECT
      site_id,
      toDate(min(timestamp)) AS date,
      session_id,
      any(visitor_id) AS visitor_id,
      argMinIf(url_path, timestamp, event_type = 'pageview') AS entry_page,
      argMaxIf(url_path, timestamp, event_type = 'pageview') AS exit_page,
      countIf(event_type = 'pageview') AS pageview_count,
      maxIf(duration_s, event_type = 'duration' AND duration_s > 0) AS duration_s,
      any(referrer_domain) AS referrer_domain,
      any(utm_source) AS utm_source,
      any(utm_medium) AS utm_medium,
      any(utm_campaign) AS utm_campaign,
      any(device_type) AS device_type,
      any(browser) AS browser,
      any(ip_country) AS ip_country,
      if(countIf(event_type = 'pageview') = 1, 1, 0) AS is_bounce
    FROM events
    WHERE #{where_clause}
      AND ip_is_bot = 0
    GROUP BY site_id, session_id
    HAVING pageview_count > 0
    """

    ClickHouse.execute(sql)
  end

  def maybe_backfill do
    case ClickHouse.query("SELECT count() AS cnt FROM daily_session_facts") do
      {:ok, [%{"cnt" => "0"}]} ->
        Logger.notice("[SessionFactsRollup] Table empty, scheduling backfill")
        %{"backfill" => true} |> __MODULE__.new() |> Oban.insert()

      {:ok, [%{"cnt" => cnt}]} when cnt in [0, "0"] ->
        Logger.notice("[SessionFactsRollup] Table empty, scheduling backfill")
        %{"backfill" => true} |> __MODULE__.new() |> Oban.insert()

      _ ->
        :ok
    end
  end
end
