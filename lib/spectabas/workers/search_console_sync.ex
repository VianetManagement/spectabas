defmodule Spectabas.Workers.SearchConsoleSync do
  @moduledoc """
  Syncs search analytics data from Google Search Console and Bing Webmaster.
  Runs daily — GSC data has a 2-3 day delay, so syncs days 2-4 ago.
  """

  use Oban.Worker, queue: :ad_sync, max_attempts: 3

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.{GoogleSearchConsole, BingWebmaster}

  @impl Oban.Worker
  def perform(_job) do
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform in ["google_search_console", "bing_webmaster"]))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()

    Enum.each(integrations, fn integration ->
      if AdIntegrations.should_sync?(integration) do
        # GSC data has a 2-3 day delay; sync days 2, 3, and 4 ago
        Enum.each(2..4, fn offset ->
          date = Date.add(today, -offset)
          sync_one(integration, date)
        end)
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
          {:error, _} -> nil
        end
      else
        integration
      end

    if integration do
      GoogleSearchConsole.sync_search_data(integration.site, integration, date)
    end
  end

  defp sync_one(%{platform: "bing_webmaster"} = integration, date) do
    BingWebmaster.sync_search_data(integration.site, integration, date)
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
  def sync_now(integration) do
    require Logger
    integration = Spectabas.Repo.preload(integration, :site)
    today = Date.utc_today()

    # First sync (never synced) = backfill 16 months (~480 days)
    # Subsequent syncs = last 7 days (GSC has 2-3 day delay)
    max_offset =
      if is_nil(integration.last_synced_at), do: 480, else: 7

    start_date = Date.add(today, -max_offset)

    Logger.info("[SearchConsoleSync] sync_now from #{start_date} (#{max_offset} days)")

    # Work forward from oldest date, skip already-synced days
    Enum.each(0..max_offset, fn offset ->
      date = Date.add(start_date, offset)

      # GSC data has 2-day delay — skip recent dates
      if Date.diff(today, date) >= 2 do
        unless gsc_day_synced?(integration.site.id, date) do
          sync_one(integration, date)
        end
      end
    end)
  end

  defp gsc_day_synced?(site_id, date) do
    sql = """
    SELECT count() AS cnt FROM search_console FINAL
    WHERE site_id = #{Spectabas.ClickHouse.param(site_id)}
      AND date = #{Spectabas.ClickHouse.param(Date.to_iso8601(date))}
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
