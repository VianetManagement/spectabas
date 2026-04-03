defmodule Spectabas.Workers.StripeSync do
  @moduledoc """
  Syncs Stripe charges into ecommerce_events. Runs every 6 hours via Oban cron.
  Syncs today + yesterday for each active Stripe integration.
  """

  use Oban.Worker, queue: :ad_sync, max_attempts: 3

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.StripePlatform

  @impl Oban.Worker
  def perform(_job) do
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform == "stripe"))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    Enum.each(integrations, fn integration ->
      StripePlatform.sync_charges(integration.site, integration, today)
      StripePlatform.sync_charges(integration.site, integration, yesterday)
    end)

    :ok
  end

  @doc "Sync a single integration for today + yesterday. Called from Settings UI."
  def sync_now(integration) do
    integration = Spectabas.Repo.preload(integration, :site)
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    StripePlatform.sync_charges(integration.site, integration, yesterday)
    StripePlatform.sync_charges(integration.site, integration, today)
  end
end
