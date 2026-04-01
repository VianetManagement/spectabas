defmodule Spectabas.Workers.ApiLogCleanup do
  @moduledoc "Deletes API access logs older than 30 days. Runs daily via Oban cron."

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query
  require Logger

  @retention_days 30

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

    :ok
  end
end
