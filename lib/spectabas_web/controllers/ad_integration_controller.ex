defmodule SpectabasWeb.AdIntegrationController do
  use SpectabasWeb, :controller

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.{GoogleAds, BingAds, MetaAds}

  require Logger

  def callback(conn, %{"platform" => platform, "code" => code, "state" => state}) do
    case Phoenix.Token.verify(SpectabasWeb.Endpoint, "ad_oauth", state, max_age: 600) do
      {:ok, site_id} ->
        site = Spectabas.Sites.get_site!(site_id)
        result = exchange_code(site, platform, code)
        handle_exchange(conn, platform, site_id, result)

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid or expired OAuth state. Please try again.")
        |> redirect(to: ~p"/dashboard")
    end
  end

  def callback(conn, %{"platform" => _platform, "error" => error}) do
    conn
    |> put_flash(:error, "Ad platform connection failed: #{error}")
    |> redirect(to: ~p"/dashboard")
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Invalid OAuth callback.")
    |> redirect(to: ~p"/dashboard")
  end

  defp exchange_code(site, "google_ads", code), do: GoogleAds.exchange_code(site, code)
  defp exchange_code(site, "bing_ads", code), do: BingAds.exchange_code(site, code)
  defp exchange_code(site, "meta_ads", code), do: MetaAds.exchange_code(site, code)
  defp exchange_code(_, _, _), do: {:error, "Unknown platform"}

  defp handle_exchange(conn, platform, site_id, {:ok, tokens}) do
    expires_at =
      if tokens[:expires_in] do
        DateTime.add(DateTime.utc_now(), tokens.expires_in, :second)
        |> DateTime.truncate(:second)
      end

    case AdIntegrations.connect(site_id, platform, %{
           access_token: tokens.access_token,
           refresh_token: tokens[:refresh_token] || tokens.access_token,
           expires_at: expires_at,
           account_id: tokens[:account_id] || "",
           account_name: tokens[:account_name] || platform_label(platform)
         }) do
      {:ok, _integration} ->
        Logger.info("[AdIntegration] Connected #{platform} for site #{site_id}")

        conn
        |> put_flash(:info, "#{platform_label(platform)} connected successfully!")
        |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")

      {:error, reason} ->
        Logger.error("[AdIntegration] Failed to save: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to save connection. Please try again.")
        |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
    end
  end

  defp handle_exchange(conn, platform, site_id, {:error, reason}) do
    Logger.warning("[AdIntegration] OAuth exchange failed for #{platform}: #{inspect(reason)}")

    conn
    |> put_flash(:error, "Failed to connect #{platform_label(platform)}. Please try again.")
    |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
  end

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label(p), do: p
end
