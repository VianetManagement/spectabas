defmodule Spectabas.Workers.StripeSync do
  @moduledoc """
  Syncs Stripe charges into ecommerce_events via Oban cron.
  Syncs today only; also syncs yesterday if last successful sync was > 6h ago.
  """

  use Oban.Worker,
    queue: :ad_sync,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :executing, :scheduled, :retryable]]

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.StripePlatform
  alias Spectabas.AdIntegrations.SyncLog
  alias Spectabas.Notifications.Slack

  @catchup_threshold_hours 6

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(300)

  @impl Oban.Worker
  def perform(_job) do
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform == "stripe"))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()

    Enum.each(integrations, fn integration ->
      if AdIntegrations.should_sync?(integration) do
        start = System.monotonic_time(:millisecond)

        try do
          dates = sync_dates(integration, today)

          Enum.each(dates, fn date ->
            StripePlatform.sync_charges(integration.site, integration, date)
          end)

          sub_result = StripePlatform.sync_subscriptions(integration.site, integration)

          ms = System.monotonic_time(:millisecond) - start

          SyncLog.log(
            integration,
            "cron_sync",
            "ok",
            "Synced charges (#{length(dates)} day(s)) and subscriptions",
            duration_ms: ms,
            details: %{
              "dates" => Enum.map(dates, &to_string/1),
              "subscriptions" => inspect(sub_result)
            }
          )
        rescue
          e ->
            ms = System.monotonic_time(:millisecond) - start
            error_msg = Exception.message(e)
            SyncLog.log(integration, "cron_sync", "error", error_msg, duration_ms: ms)
            Slack.sync_failed("StripeSync", integration.site.name, error_msg)
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
        error_msg = Exception.message(e)

        SyncLog.log(
          integration,
          "manual_sync",
          "error",
          "#{error_msg}\n#{Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0, 300)}",
          duration_ms: ms
        )

        Slack.sync_failed("StripeSync (manual)", integration.site.name, error_msg)
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
