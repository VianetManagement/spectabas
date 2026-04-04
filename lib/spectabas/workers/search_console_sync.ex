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

  @doc "Manual sync for a specific integration."
  def sync_now(integration) do
    integration = Spectabas.Repo.preload(integration, :site)
    today = Date.utc_today()

    # Sync last 7 days (GSC has 2-3 day delay)
    Enum.each(2..7, fn offset ->
      sync_one(integration, Date.add(today, -offset))
    end)
  end
end
