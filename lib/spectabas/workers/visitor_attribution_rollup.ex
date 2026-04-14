defmodule Spectabas.Workers.VisitorAttributionRollup do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.ClickHouse

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"backfill" => true}}) do
    Logger.notice("[VisitorAttributionRollup] Historical backfill starting")
    run_for_all_sites()
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    Logger.notice("[VisitorAttributionRollup] Daily run starting")
    run_for_all_sites()
  end

  defp run_for_all_sites do
    case ClickHouse.query("SELECT DISTINCT site_id FROM events WHERE ip_is_bot = 0") do
      {:ok, rows} ->
        site_ids = Enum.map(rows, fn r -> r["site_id"] end)

        results =
          Enum.map(site_ids, fn site_id ->
            run_for_site(site_id)
          end)

        if Enum.any?(results, &match?({:error, _}, &1)) do
          Logger.error("[VisitorAttributionRollup] Some sites failed")
          {:error, "partial failure"}
        else
          Logger.notice("[VisitorAttributionRollup] Completed for #{length(site_ids)} sites")
          :ok
        end

      {:error, reason} ->
        Logger.error("[VisitorAttributionRollup] Failed to list sites: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  defp run_for_site(site_id) do
    site_p = ClickHouse.param(site_id)

    sql = """
    INSERT INTO visitor_attribution
    SELECT
      site_id,
      visitor_id,
      argMinIf(if(referrer_domain != '', referrer_domain, if(utm_source != '', utm_source, 'Direct')), timestamp, event_type = 'pageview') AS first_source,
      argMinIf(utm_medium, timestamp, event_type = 'pageview') AS first_medium,
      argMinIf(utm_campaign, timestamp, event_type = 'pageview') AS first_campaign,
      argMaxIf(if(referrer_domain != '', referrer_domain, if(utm_source != '', utm_source, 'Direct')), timestamp, event_type = 'pageview') AS last_source,
      argMaxIf(utm_medium, timestamp, event_type = 'pageview') AS last_medium,
      argMaxIf(utm_campaign, timestamp, event_type = 'pageview') AS last_campaign,
      min(timestamp) AS first_seen,
      max(timestamp) AS last_seen,
      now() AS updated_at
    FROM events
    WHERE site_id = #{site_p} AND ip_is_bot = 0
    GROUP BY site_id, visitor_id
    """

    case ClickHouse.execute(sql) do
      :ok ->
        Logger.notice("[VisitorAttributionRollup] site_id=#{site_id} done")
        :ok

      {:error, reason} ->
        Logger.error("[VisitorAttributionRollup] site_id=#{site_id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def maybe_backfill do
    case ClickHouse.query("SELECT count() AS cnt FROM visitor_attribution") do
      {:ok, [%{"cnt" => "0"}]} ->
        Logger.notice("[VisitorAttributionRollup] Table empty, scheduling backfill")
        %{"backfill" => true} |> __MODULE__.new() |> Oban.insert()

      {:ok, [%{"cnt" => cnt}]} when cnt in [0, "0"] ->
        Logger.notice("[VisitorAttributionRollup] Table empty, scheduling backfill")
        %{"backfill" => true} |> __MODULE__.new() |> Oban.insert()

      _ ->
        :ok
    end
  end
end
