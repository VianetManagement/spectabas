defmodule Spectabas.Workers.BraintreeSync do
  @moduledoc """
  Syncs Braintree transactions, refunds, and subscriptions.
  Runs on the same schedule as StripeSync — frequency controlled per-integration.
  """

  use Oban.Worker, queue: :ad_sync, max_attempts: 3

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.BraintreePlatform

  @impl Oban.Worker
  def perform(_job) do
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform == "braintree"))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    Enum.each(integrations, fn integration ->
      if AdIntegrations.should_sync?(integration) do
        BraintreePlatform.sync_transactions(integration.site, integration, today)
        BraintreePlatform.sync_transactions(integration.site, integration, yesterday)
        BraintreePlatform.sync_refunds(integration.site, integration, today)
        BraintreePlatform.sync_refunds(integration.site, integration, yesterday)
        BraintreePlatform.sync_subscriptions(integration.site, integration)
      end
    end)

    :ok
  end

  @doc "Sync a single integration. Called from Settings UI."
  def sync_now(integration) do
    integration = Spectabas.Repo.preload(integration, :site)
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    BraintreePlatform.sync_transactions(integration.site, integration, yesterday)
    BraintreePlatform.sync_transactions(integration.site, integration, today)
    BraintreePlatform.sync_refunds(integration.site, integration, yesterday)
    BraintreePlatform.sync_refunds(integration.site, integration, today)
    BraintreePlatform.sync_subscriptions(integration.site, integration)
  end
end
