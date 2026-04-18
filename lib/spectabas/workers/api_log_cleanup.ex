defmodule Spectabas.Workers.ApiLogCleanup do
  @moduledoc "Deletes API access logs older than 30 days. Runs daily via Oban cron."

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query
  require Logger

  @retention_days 30

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)

    {count, _} =
      Spectabas.Repo.delete_all(
        from(l in Spectabas.Accounts.ApiAccessLog, where: l.inserted_at < ^cutoff)
      )

    if count > 0 do
      Logger.info(
        "[ApiLogCleanup] Deleted #{count} API access logs older than #{@retention_days} days"
      )
    end

    # Also clean up old sync logs
    {sync_count, _} = Spectabas.AdIntegrations.SyncLog.cleanup(@retention_days)

    if sync_count > 0 do
      Logger.info(
        "[ApiLogCleanup] Deleted #{sync_count} sync logs older than #{@retention_days} days"
      )
    end

    # Clean up old webhook delivery logs
    wh_count = Spectabas.Webhooks.ScraperWebhook.cleanup_old_deliveries(@retention_days)

    if wh_count > 0 do
      Logger.info(
        "[ApiLogCleanup] Deleted #{wh_count} webhook deliveries older than #{@retention_days} days"
      )
    end

    :ok
  end
end
