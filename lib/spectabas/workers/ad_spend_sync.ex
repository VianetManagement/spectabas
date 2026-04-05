defmodule Spectabas.Workers.AdSpendSync do
  @moduledoc "Syncs ad spend data from connected ad platforms. Runs every 6 hours via Oban cron."

  use Oban.Worker, queue: :ad_sync, max_attempts: 3

  require Logger

  alias Spectabas.{AdIntegrations, ClickHouse}
  alias Spectabas.AdIntegrations.Platforms.{GoogleAds, BingAds, MetaAds}
  import Spectabas.TypeHelpers, only: [to_int: 1]

  @impl Oban.Worker
  def perform(_job) do
    # Only process ad platforms — Stripe/Braintree/GSC/Bing have their own sync workers
    integrations =
      AdIntegrations.list_active()
      |> Enum.filter(&(&1.platform in ["google_ads", "bing_ads", "meta_ads"]))
      |> Spectabas.Repo.preload(:site)

    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    Enum.each(integrations, fn integration ->
      # Always sync today (partial data updates throughout the day)
      sync_integration(integration, today)
      # Sync yesterday only if we haven't yet today (avoid duplicate inserts)
      unless synced_date_today?(integration, yesterday) do
        sync_integration(integration, yesterday)
      end
    end)

    :ok
  end

  # Check if this integration already synced a given date during the current UTC day
  defp synced_date_today?(integration, date) do
    case integration.last_synced_at do
      nil ->
        false

      ts ->
        Date.compare(DateTime.to_date(ts), Date.utc_today()) == :eq and
          already_has_data?(integration, date)
    end
  end

  defp already_has_data?(integration, date) do
    sql = """
    SELECT count() AS cnt FROM ad_spend FINAL
    WHERE site_id = #{ClickHouse.param(integration.site_id)}
      AND platform = #{ClickHouse.param(integration.platform)}
      AND date = #{ClickHouse.param(Date.to_iso8601(date))}
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"cnt" => cnt}]} -> to_int(cnt) > 0
      _ -> false
    end
  end

  @doc "Sync a single integration for a given date. Called by AdSpendSyncOne."
  def sync_one(integration, date), do: sync_integration(integration, date)

  defp sync_integration(integration, date) do
    # Refresh token if expired
    integration =
      if AdIntegrations.token_expired?(integration) do
        case refresh(integration) do
          {:ok, updated} ->
            updated

          {:error, reason} ->
            AdIntegrations.mark_error(integration, "Token refresh failed: #{inspect(reason)}")
            nil
        end
      else
        integration
      end

    if integration do
      case fetch_spend(integration.site, integration, date) do
        {:ok, rows} when rows != [] ->
          ch_rows =
            Enum.map(rows, fn row ->
              %{
                "site_id" => integration.site_id,
                "date" => Date.to_iso8601(date),
                "platform" => integration.platform,
                "account_id" => integration.account_id || "",
                "campaign_id" => to_string(row.campaign_id),
                "campaign_name" => row.campaign_name || "",
                "spend" => row.spend || 0,
                "clicks" => row.clicks || 0,
                "impressions" => row.impressions || 0,
                "currency" => integration.extra["currency"] || "USD",
                "synced_at" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
              }
            end)

          case ClickHouse.insert("ad_spend", ch_rows) do
            :ok ->
              Logger.info(
                "[AdSpendSync] #{integration.platform}: #{length(ch_rows)} campaigns synced for #{date}"
              )

              AdIntegrations.mark_synced(integration)

            {:error, reason} ->
              Logger.error(
                "[AdSpendSync] CH insert failed: #{inspect(reason) |> String.slice(0, 200)}"
              )

              AdIntegrations.mark_error(integration, "ClickHouse insert failed")
          end

        {:ok, []} ->
          Logger.info("[AdSpendSync] #{integration.platform}: no spend data for #{date}")
          AdIntegrations.mark_synced(integration)

        {:error, reason} ->
          Logger.warning(
            "[AdSpendSync] #{integration.platform} fetch failed: #{inspect(reason) |> String.slice(0, 200)}"
          )

          AdIntegrations.mark_error(integration, reason)
      end
    end
  end

  defp fetch_spend(site, %{platform: "google_ads"} = i, date),
    do: GoogleAds.fetch_daily_spend(site, i, date)

  defp fetch_spend(site, %{platform: "bing_ads"} = i, date),
    do: BingAds.fetch_daily_spend(site, i, date)

  defp fetch_spend(site, %{platform: "meta_ads"} = i, date),
    do: MetaAds.fetch_daily_spend(site, i, date)

  defp fetch_spend(_, _, _), do: {:error, "unknown platform"}

  defp refresh(%{platform: "google_ads", site: site} = integration) do
    rt = AdIntegrations.decrypt_refresh_token(integration)

    case GoogleAds.refresh_token(site, rt) do
      {:ok, tokens} ->
        expires_at =
          DateTime.add(DateTime.utc_now(), tokens.expires_in || 3600, :second)
          |> DateTime.truncate(:second)

        AdIntegrations.update_tokens(integration, tokens.access_token, rt, expires_at)

      error ->
        error
    end
  end

  defp refresh(%{platform: "bing_ads", site: site} = integration) do
    rt = AdIntegrations.decrypt_refresh_token(integration)

    case BingAds.refresh_token(site, rt) do
      {:ok, tokens} ->
        expires_at =
          DateTime.add(DateTime.utc_now(), tokens.expires_in || 3600, :second)
          |> DateTime.truncate(:second)

        AdIntegrations.update_tokens(integration, tokens.access_token, rt, expires_at)

      error ->
        error
    end
  end

  defp refresh(%{platform: "meta_ads", site: site} = integration) do
    at = AdIntegrations.decrypt_access_token(integration)

    case MetaAds.refresh_token(site, at) do
      {:ok, tokens} ->
        expires_at =
          DateTime.add(DateTime.utc_now(), tokens.expires_in || 5_184_000, :second)
          |> DateTime.truncate(:second)

        AdIntegrations.update_tokens(
          integration,
          tokens.access_token,
          tokens.access_token,
          expires_at
        )

      error ->
        error
    end
  end

  defp refresh(_), do: {:error, "unknown platform"}
end
