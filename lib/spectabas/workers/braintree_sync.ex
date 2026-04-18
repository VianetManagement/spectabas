defmodule Spectabas.Workers.BraintreeSync do
  @moduledoc """
  Syncs Braintree transactions, refunds, and subscriptions.
  Syncs today only; also syncs yesterday if last successful sync was > 6h ago.
  """

  use Oban.Worker,
    queue: :ad_sync,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :executing, :scheduled, :retryable]]

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.BraintreePlatform
  alias Spectabas.AdIntegrations.SyncLog
  alias Spectabas.Notifications.Slack

  @catchup_threshold_hours 6

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(300)

  @impl Oban.Worker
  def perform(_job) do
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform == "braintree"))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()

    Enum.each(integrations, fn integration ->
      if AdIntegrations.should_sync?(integration) do
        start = System.monotonic_time(:millisecond)

        try do
          dates = sync_dates(integration, today)

          Enum.each(dates, fn date ->
            BraintreePlatform.sync_transactions(integration.site, integration, date)
            BraintreePlatform.sync_refunds(integration.site, integration, date)
          end)

          BraintreePlatform.sync_subscriptions(integration.site, integration)

          ms = System.monotonic_time(:millisecond) - start

          SyncLog.log(
            integration,
            "cron_sync",
            "ok",
            "Synced transactions, refunds (#{length(dates)} day(s)), subscriptions",
            duration_ms: ms
          )
        rescue
          e ->
            ms = System.monotonic_time(:millisecond) - start
            error_msg = Exception.message(e)
            SyncLog.log(integration, "cron_sync", "error", error_msg, duration_ms: ms)
            Slack.sync_failed("BraintreeSync", integration.site.name, error_msg)
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

      SyncLog.log(integration, "manual_sync", "ok", "Synced transactions, refunds, subscriptions",
        duration_ms: ms
      )
    rescue
      e ->
        ms = System.monotonic_time(:millisecond) - start
        error_msg = Exception.message(e)
        SyncLog.log(integration, "manual_sync", "error", error_msg, duration_ms: ms)
        Slack.sync_failed("BraintreeSync (manual)", integration.site.name, error_msg)
    end
  end

  # Sync today; also sync yesterday if last successful sync was > 6h ago
  defp sync_dates(integration, today) do
    if needs_catchup?(integration) do
      [today, Date.add(today, -1)]
    else
      [today]
    end
  end

  defp needs_catchup?(integration) do
    case integration.last_synced_at do
      nil -> true
      last -> DateTime.diff(DateTime.utc_now(), last, :hour) >= @catchup_threshold_hours
    end
  end
end
