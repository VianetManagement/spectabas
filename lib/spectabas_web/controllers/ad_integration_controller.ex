defmodule SpectabasWeb.AdIntegrationController do
  use SpectabasWeb, :controller

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Platforms.{GoogleAds, BingAds, MetaAds}

  require Logger

  def callback(conn, %{"platform" => platform, "code" => code, "state" => state}) do
    case Phoenix.Token.verify(SpectabasWeb.Endpoint, "ad_oauth", state, max_age: 600) do
      {:ok, site_id} ->
        site = Spectabas.Sites.get_site!(site_id)
        handle_platform_callback(conn, platform, site, code)

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

  # Google Ads: exchange code, then check if multiple accounts need selection
  defp handle_platform_callback(conn, "google_ads", site, code) do
    with {:ok, tokens} <- GoogleAds.exchange_code(site, code) do
      creds = Spectabas.AdIntegrations.Credentials.get_for_platform(site, "google_ads")
      dev_token = creds["developer_token"]

      case GoogleAds.list_accessible_customers(tokens.access_token, dev_token) do
        {:ok, [single]} ->
          # Only one account — connect directly
          merged = Map.merge(tokens, %{account_id: single.id, account_name: single.name})
          save_and_redirect(conn, "google_ads", site.id, merged)

        {:ok, customers} when length(customers) > 1 ->
          # Multiple accounts — store tokens in session, redirect to picker
          conn
          |> put_session(:google_ads_pending_tokens, %{
            "access_token" => tokens.access_token,
            "refresh_token" => tokens.refresh_token,
            "expires_in" => tokens.expires_in,
            "site_id" => site.id,
            "customers" => Enum.map(customers, fn c -> %{"id" => c.id, "name" => c.name} end)
          })
          |> redirect(to: ~p"/auth/ad/google_ads/pick_account?site_id=#{site.id}")

        {:ok, []} ->
          conn
          |> put_flash(:error, "No Google Ads accounts found for this user.")
          |> redirect(to: ~p"/dashboard/sites/#{site.id}/settings")

        {:error, reason} ->
          Logger.warning("[AdIntegration] listAccessibleCustomers failed: #{inspect(reason)}")
          save_and_redirect(conn, "google_ads", site.id, tokens)
      end
    else
      {:error, reason} ->
        Logger.warning("[AdIntegration] Google Ads OAuth failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to connect Google Ads. Please try again.")
        |> redirect(to: ~p"/dashboard/sites/#{site.id}/settings")
    end
  end

  defp handle_platform_callback(conn, "bing_ads", site, code) do
    case BingAds.exchange_code(site, code) do
      {:ok, tokens} -> save_and_redirect(conn, "bing_ads", site.id, tokens)
      {:error, reason} -> exchange_error(conn, "Microsoft Ads", site.id, reason)
    end
  end

  defp handle_platform_callback(conn, "meta_ads", site, code) do
    case MetaAds.exchange_code(site, code) do
      {:ok, tokens} -> save_and_redirect(conn, "meta_ads", site.id, tokens)
      {:error, reason} -> exchange_error(conn, "Meta Ads", site.id, reason)
    end
  end

  defp handle_platform_callback(conn, _, _site, _code) do
    conn
    |> put_flash(:error, "Unknown ad platform.")
    |> redirect(to: ~p"/dashboard")
  end

  # Account picker page — shows list of Google Ads accounts
  def pick_account(conn, %{"site_id" => site_id}) do
    pending = get_session(conn, :google_ads_pending_tokens)
    site_id_int = String.to_integer(site_id)

    if is_map(pending) && (pending["site_id"] || pending[:site_id]) == site_id_int do
      customers = pending["customers"] || pending[:customers] || []
      render(conn, :pick_account, site_id: site_id, customers: customers)
    else
      conn
      |> put_flash(:error, "Session expired. Please reconnect Google Ads.")
      |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
    end
  end

  # User selected an account from the picker
  def select_account(conn, %{"site_id" => site_id, "account_id" => account_id}) do
    pending = get_session(conn, :google_ads_pending_tokens)

    # Handle both atom and string keys from session
    tokens = normalize_pending(pending)

    if tokens do
      customers = tokens["customers"] || []
      selected = Enum.find(customers, fn c -> (c["id"] || c[:id]) == account_id end)
      name = (selected && (selected["name"] || selected[:name])) || account_id

      merged = %{
        access_token: tokens["access_token"],
        refresh_token: tokens["refresh_token"],
        expires_in: tokens["expires_in"],
        account_id: account_id,
        account_name: name
      }

      conn
      |> delete_session(:google_ads_pending_tokens)
      |> save_and_redirect("google_ads", String.to_integer(site_id), merged)
    else
      conn
      |> put_flash(:error, "Session expired. Please reconnect Google Ads.")
      |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
    end
  end

  defp normalize_pending(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp normalize_pending(_), do: nil

  defp save_and_redirect(conn, platform, site_id, tokens) do
    expires_at =
      if tokens[:expires_in] do
        DateTime.add(DateTime.utc_now(), tokens.expires_in, :second)
        |> DateTime.truncate(:second)
      end

    case AdIntegrations.connect(site_id, platform, %{
           access_token: tokens.access_token || tokens[:access_token],
           refresh_token: tokens[:refresh_token] || tokens[:access_token],
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

  defp exchange_error(conn, label, site_id, reason) do
    Logger.warning("[AdIntegration] OAuth exchange failed for #{label}: #{inspect(reason)}")

    conn
    |> put_flash(:error, "Failed to connect #{label}. Please try again.")
    |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
  end

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label(p), do: p
end
