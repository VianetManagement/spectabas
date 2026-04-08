defmodule Spectabas.Workers.StripeSync do
  @moduledoc """
  Syncs Stripe charges into ecommerce_events. Runs every 6 hours via Oban cron.
  Syncs today + yesterday for each active Stripe integration.
  """

  use Oban.Worker,
    queue: :ad_sync,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :executing, :scheduled, :retryable]]

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.StripePlatform
  alias Spectabas.AdIntegrations.SyncLog

  @impl Oban.Worker
  def perform(_job) do
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform == "stripe"))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    Enum.each(integrations, fn integration ->
      if AdIntegrations.should_sync?(integration) do
        start = System.monotonic_time(:millisecond)

        try do
          StripePlatform.sync_charges(integration.site, integration, today)
          StripePlatform.sync_charges(integration.site, integration, yesterday)
          sub_result = StripePlatform.sync_subscriptions(integration.site, integration)

          ms = System.monotonic_time(:millisecond) - start

          SyncLog.log(
            integration,
            "cron_sync",
            "ok",
            "Synced charges (today+yesterday) and subscriptions",
            duration_ms: ms,
            details: %{
              "dates" => [to_string(today), to_string(yesterday)],
              "subscriptions" => inspect(sub_result)
            }
          )
        rescue
          e ->
            ms = System.monotonic_time(:millisecond) - start
            SyncLog.log(integration, "cron_sync", "error", Exception.message(e), duration_ms: ms)
        end
      end
    end)

    :ok
  end

  @doc "Sync a single integration. On first sync (never synced before), backfills 30 days."
  def sync_now(integration) do
    integration = Spectabas.Repo.preload(integration, :site)
    today = Date.utc_today()
    start = System.monotonic_time(:millisecond)

    # If never synced, backfill last 30 days; otherwise just today + yesterday
    days =
      if is_nil(integration.last_synced_at), do: 30, else: 1

    SyncLog.log(integration, "manual_sync_start", "ok", "Sync Now triggered (#{days + 1} days)")

    try do
      Enum.each(0..days, fn offset ->
        StripePlatform.sync_charges(integration.site, integration, Date.add(today, -offset))
      end)

      sub_result = StripePlatform.sync_subscriptions(integration.site, integration)
      ms = System.monotonic_time(:millisecond) - start

      sub_msg =
        case sub_result do
          :ok -> "subscriptions synced"
          {:error, reason} -> "subscriptions failed: #{inspect(reason) |> String.slice(0, 100)}"
          other -> "subscriptions: #{inspect(other) |> String.slice(0, 100)}"
        end

      SyncLog.log(integration, "manual_sync", "ok", "Charges (#{days + 1} days), #{sub_msg}",
        duration_ms: ms,
        details: %{"days" => days + 1}
      )
    rescue
      e ->
        ms = System.monotonic_time(:millisecond) - start

        SyncLog.log(
          integration,
          "manual_sync",
          "error",
          "#{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 300)}",
          duration_ms: ms
        )
    catch
      kind, reason ->
        ms = System.monotonic_time(:millisecond) - start

        SyncLog.log(
          integration,
          "manual_sync",
          "error",
          "#{kind}: #{inspect(reason) |> String.slice(0, 300)}",
          duration_ms: ms
        )
    end
  end
end
