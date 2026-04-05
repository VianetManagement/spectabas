defmodule Spectabas.Workers.SearchConsoleSync do
  @moduledoc """
  Syncs search analytics data from Google Search Console and Bing Webmaster.
  Runs daily — GSC data has a 2-3 day delay, so syncs days 2-4 ago.
  """

  use Oban.Worker, queue: :ad_sync, max_attempts: 3

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.{GoogleSearchConsole, BingWebmaster}
  alias Spectabas.AdIntegrations.SyncLog

  @impl Oban.Worker
  def perform(_job) do
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform in ["google_search_console", "bing_webmaster"]))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()

    Enum.each(integrations, fn integration ->
      if AdIntegrations.should_sync?(integration) do
        start = System.monotonic_time(:millisecond)
        dates = Enum.map(2..4, &Date.add(today, -&1))
        synced = Enum.count(dates, fn date -> sync_one(integration, date) == :ok end)
        ms = System.monotonic_time(:millisecond) - start

        SyncLog.log(integration, "cron_sync", "ok",
          "Synced #{synced}/#{length(dates)} days (#{Enum.map(dates, &to_string/1) |> Enum.join(", ")})",
          duration_ms: ms,
          details: %{"dates_synced" => synced, "dates_total" => length(dates)}
        )
      end
    end)

    :ok
  end

  defp sync_one(%{platform: "google_search_console"} = integration, date) do
    # Refresh token if expired
    integration =
      if AdIntegrations.token_expired?(integration) do
        case refresh_gsc_token(integration) do
          {:ok, updated} -> updated

          {:error, reason} ->
            SyncLog.log(integration, "token_refresh", "error", "Token refresh failed: #{inspect(reason)}")
            nil
        end
      else
        integration
      end

    if integration do
      case GoogleSearchConsole.sync_search_data(integration.site, integration, date) do
        :ok -> :ok
        {:error, reason} ->
          SyncLog.log(integration, "day_sync", "error", "#{date}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :token_refresh_failed}
    end
  end

  defp sync_one(%{platform: "bing_webmaster"} = integration, date) do
    case BingWebmaster.sync_search_data(integration.site, integration, date) do
      :ok -> :ok
      {:error, reason} ->
        SyncLog.log(integration, "day_sync", "error", "#{date}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sync_one(_, _), do: :ok

  defp refresh_gsc_token(integration) do
    rt = AdIntegrations.decrypt_refresh_token(integration)

    case GoogleSearchConsole.refresh_token(integration.site, rt) do
      {:ok, %{access_token: at, expires_in: ei}} ->
        expires_at =
          DateTime.utc_now()
          |> DateTime.add(ei || 3600, :second)
          |> DateTime.truncate(:second)

        AdIntegrations.update_tokens(integration, at, rt, expires_at)

      {:error, reason} ->
        AdIntegrations.mark_error(integration, "Token refresh failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Manual sync. First sync backfills 16 months, subsequent syncs do last 7 days."
  def sync_now(integration, opts \\ []) do
    require Logger
    integration = Spectabas.Repo.preload(integration, :site)
    today = Date.utc_today()
    start_time = System.monotonic_time(:millisecond)

    # Force backfill ignores last_synced_at — always does full 16 months
    force_backfill = Keyword.get(opts, :force_backfill, false)

    max_offset =
      if is_nil(integration.last_synced_at) or force_backfill, do: 480, else: 7

    start_date = Date.add(today, -max_offset)

    # force_backfill also skips the "already synced" check — re-syncs all days
    SyncLog.log(integration, "manual_sync_start", "ok",
      "Backfill from #{start_date} (#{max_offset} days, force=#{force_backfill})")

    Logger.info("[SearchConsoleSync] sync_now from #{start_date} (#{max_offset} days, force=#{force_backfill})")

    synced = Enum.reduce(0..max_offset, 0, fn offset, acc ->
      date = Date.add(start_date, offset)

      if Date.diff(today, date) >= 2 do
        source = if integration.platform == "bing_webmaster", do: "bing", else: "google"
        should_sync = force_backfill or not gsc_day_synced?(integration.site.id, date, source)

        if should_sync do
          # Throttle Bing API calls — their rate limit is strict
          if integration.platform == "bing_webmaster" and acc > 0, do: Process.sleep(1500)

          case sync_one(integration, date) do
            :ok -> acc + 1
            _ -> acc
          end
        else
          acc
        end
      else
        acc
      end
    end)

    ms = System.monotonic_time(:millisecond) - start_time

    SyncLog.log(integration, "manual_sync", "ok",
      "Backfill complete: #{synced} days synced from #{start_date}",
      duration_ms: ms,
      details: %{"days_synced" => synced, "total_days" => max_offset, "start_date" => to_string(start_date)}
    )
  end

  defp gsc_day_synced?(site_id, date, source) do
    sql = """
    SELECT count() AS cnt FROM search_console FINAL
    WHERE site_id = #{Spectabas.ClickHouse.param(site_id)}
      AND date = #{Spectabas.ClickHouse.param(Date.to_iso8601(date))}
      AND source = #{Spectabas.ClickHouse.param(source)}
    """

    case Spectabas.ClickHouse.query(sql) do
      {:ok, [%{"cnt" => cnt}]} ->
        case cnt do
          n when is_integer(n) -> n > 0
          n when is_binary(n) -> String.to_integer(n) > 0
          _ -> false
        end

      _ ->
        false
    end
  end
end
