defmodule Spectabas.Workers.BraintreeSync do
  @moduledoc """
  Syncs Braintree transactions, refunds, and subscriptions.
  Runs on the same schedule as StripeSync — frequency controlled per-integration.
  """

  use Oban.Worker, queue: :ad_sync, max_attempts: 3, unique: [period: 300, states: [:available, :executing, :scheduled, :retryable]]

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.BraintreePlatform
  alias Spectabas.AdIntegrations.SyncLog

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
        start = System.monotonic_time(:millisecond)

        try do
          BraintreePlatform.sync_transactions(integration.site, integration, today)
          BraintreePlatform.sync_transactions(integration.site, integration, yesterday)
          BraintreePlatform.sync_refunds(integration.site, integration, today)
          BraintreePlatform.sync_refunds(integration.site, integration, yesterday)
          BraintreePlatform.sync_subscriptions(integration.site, integration)

          ms = System.monotonic_time(:millisecond) - start
          SyncLog.log(integration, "cron_sync", "ok", "Synced transactions, refunds, subscriptions", duration_ms: ms)
        rescue
          e ->
            ms = System.monotonic_time(:millisecond) - start
            SyncLog.log(integration, "cron_sync", "error", Exception.message(e), duration_ms: ms)
        end
      end
    end)

    :ok
  end

  @doc "Sync a single integration. Called from Settings UI."
  def sync_now(integration) do
    integration = Spectabas.Repo.preload(integration, :site)
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    start = System.monotonic_time(:millisecond)

    SyncLog.log(integration, "manual_sync_start", "ok", "Sync Now triggered")

    try do
      BraintreePlatform.sync_transactions(integration.site, integration, yesterday)
      BraintreePlatform.sync_transactions(integration.site, integration, today)
      BraintreePlatform.sync_refunds(integration.site, integration, yesterday)
      BraintreePlatform.sync_refunds(integration.site, integration, today)
      BraintreePlatform.sync_subscriptions(integration.site, integration)

      ms = System.monotonic_time(:millisecond) - start
      SyncLog.log(integration, "manual_sync", "ok", "Synced transactions, refunds, subscriptions", duration_ms: ms)
    rescue
      e ->
        ms = System.monotonic_time(:millisecond) - start
        SyncLog.log(integration, "manual_sync", "error", Exception.message(e), duration_ms: ms)
    end
  end
end
