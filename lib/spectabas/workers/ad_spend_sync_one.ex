defmodule Spectabas.Workers.AdSpendSyncOne do
  @moduledoc "Syncs ad spend for a single integration. Triggered manually from settings."

  use Oban.Worker, queue: :ad_sync, max_attempts: 1

  require Logger

  alias Spectabas.{AdIntegrations, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => id}}) do
    integration = AdIntegrations.get!(id) |> Repo.preload(:site)
    yesterday = Date.add(Date.utc_today(), -1)

    Spectabas.Workers.AdSpendSync.sync_one(integration, yesterday)
    :ok
  end
end
