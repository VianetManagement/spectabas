defmodule SpectabasWeb.AdIntegrationController do
  use SpectabasWeb, :controller

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.{Vault}
  alias Spectabas.AdIntegrations.Platforms.{GoogleAds, BingAds, MetaAds}

  require Logger

  # Encrypt sensitive token data before storing in session cookie
  defp encrypt_session_tokens(data) do
    data
    |> Jason.encode!()
    |> Vault.encrypt()
    |> Base.encode64()
  end

  # Decrypt session tokens, returns nil on failure
  defp decrypt_session_tokens(nil), do: nil

  defp decrypt_session_tokens(encoded) when is_binary(encoded) do
    with {:ok, encrypted} <- Base.decode64(encoded),
         json when is_binary(json) <- Vault.decrypt(encrypted),
         {:ok, data} <- Jason.decode(json) do
      data
    else
      _ -> nil
    end
  end

  defp decrypt_session_tokens(_), do: nil

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
          |> put_session(
            :google_ads_pending_tokens,
            encrypt_session_tokens(%{
              "access_token" => tokens.access_token,
              "refresh_token" => tokens.refresh_token,
              "expires_in" => tokens.expires_in,
              "site_id" => site.id,
              "customers" => Enum.map(customers, fn c -> %{"id" => c.id, "name" => c.name} end)
            })
          )
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
    creds = Spectabas.AdIntegrations.Credentials.get_for_platform(site, "bing_ads")

    with {:ok, tokens} <- BingAds.exchange_code(site, code),
         {:ok, accounts} <- BingAds.fetch_accounts(tokens.access_token, creds["developer_token"]) do
      case accounts do
        [single] ->
          merged =
            Map.merge(tokens, %{
              account_id: single.id,
              account_name: single.name,
              extra: %{"customer_id" => single.customer_id}
            })

          save_and_redirect(conn, "bing_ads", site.id, merged)

        [] ->
          conn
          |> put_flash(:error, "No Microsoft Ads accounts found for this user.")
          |> redirect(to: ~p"/dashboard/sites/#{site.id}/settings")

        multiple ->
          conn
          |> put_session(
            :bing_ads_pending_tokens,
            encrypt_session_tokens(%{
              "access_token" => tokens.access_token,
              "refresh_token" => tokens.refresh_token,
              "expires_in" => tokens.expires_in,
              "site_id" => site.id,
              "accounts" =>
                Enum.map(multiple, fn a ->
                  %{
                    "id" => a.id,
                    "name" => a.name,
                    "customer_id" => a.customer_id,
                    "number" => a.number
                  }
                end)
            })
          )
          |> redirect(to: ~p"/auth/ad/bing_ads/pick_account?site_id=#{site.id}")
      end
    else
      {:error, reason} -> exchange_error(conn, "Microsoft Ads", site.id, reason)
    end
  end

  defp handle_platform_callback(conn, "meta_ads", site, code) do
    case MetaAds.exchange_code(site, code) do
      {:ok, tokens} ->
        case MetaAds.fetch_ad_accounts(tokens.access_token) do
          {:ok, [single]} ->
            merged = Map.merge(tokens, %{account_id: single.id, account_name: single.name})
            save_and_redirect(conn, "meta_ads", site.id, merged)

          {:ok, []} ->
            conn
            |> put_flash(
              :error,
              "No Meta ad accounts found for this user. Make sure the Facebook account has access to at least one ad account."
            )
            |> redirect(to: ~p"/dashboard/sites/#{site.id}/settings")

          {:ok, multiple} ->
            conn
            |> put_session(
              :meta_ads_pending_tokens,
              encrypt_session_tokens(%{
                "access_token" => tokens.access_token,
                "refresh_token" => tokens[:refresh_token] || tokens.access_token,
                "expires_in" => tokens[:expires_in],
                "site_id" => site.id,
                "accounts" =>
                  Enum.map(multiple, fn a ->
                    %{"id" => a.id, "name" => a.name, "currency" => a.currency}
                  end)
              })
            )
            |> redirect(to: ~p"/auth/ad/meta_ads/pick_account?site_id=#{site.id}")

          {:error, reason} ->
            Logger.warning("[AdIntegration] Meta fetch_ad_accounts failed: #{inspect(reason)}")
            detail = if is_map(reason), do: inspect(reason), else: to_string(reason)

            conn
            |> put_flash(
              :error,
              "Meta Ads connected but couldn't fetch ad accounts: #{String.slice(detail, 0, 150)}"
            )
            |> redirect(to: ~p"/dashboard/sites/#{site.id}/settings")
        end

      {:error, reason} ->
        exchange_error(conn, "Meta Ads", site.id, reason)
    end
  end

  defp handle_platform_callback(conn, "google_search_console", site, code) do
    alias Spectabas.AdIntegrations.Platforms.GoogleSearchConsole

    case GoogleSearchConsole.exchange_code(site, code) do
      {:ok, tokens} ->
        # List available GSC properties
        case GoogleSearchConsole.list_sites(tokens.access_token) do
          {:ok, [single]} ->
            merged =
              Map.merge(tokens, %{
                account_id: single.url,
                account_name: single.url,
                extra: %{"site_url" => single.url}
              })

            save_and_redirect(conn, "google_search_console", site.id, merged)

          {:ok, sites} when length(sites) > 1 ->
            # For now, pick the first one that matches the site's parent domain
            parent = Spectabas.Sites.parent_domain_for(site)

            selected =
              Enum.find(sites, List.first(sites), fn s ->
                String.contains?(s.url, parent || "")
              end)

            merged =
              Map.merge(tokens, %{
                account_id: selected.url,
                account_name: selected.url,
                extra: %{"site_url" => selected.url}
              })

            save_and_redirect(conn, "google_search_console", site.id, merged)

          {:ok, []} ->
            conn
            |> put_flash(
              :error,
              "No Search Console properties found. Verify your site is added in GSC."
            )
            |> redirect(to: ~p"/dashboard/sites/#{site.id}/settings")

          {:error, reason} ->
            conn
            |> put_flash(:error, "Failed to list GSC properties: #{reason}")
            |> redirect(to: ~p"/dashboard/sites/#{site.id}/settings")
        end

      {:error, reason} ->
        exchange_error(conn, "Google Search Console", site.id, reason)
    end
  end

  defp handle_platform_callback(conn, _, _site, _code) do
    conn
    |> put_flash(:error, "Unknown ad platform.")
    |> redirect(to: ~p"/dashboard")
  end

  # Account picker page — shows list of Google Ads accounts
  def pick_account(conn, %{"site_id" => site_id}) do
    pending = get_session(conn, :google_ads_pending_tokens) |> decrypt_session_tokens()
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
    pending = get_session(conn, :google_ads_pending_tokens) |> decrypt_session_tokens()

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

  # Meta Ads account picker page
  def meta_pick_account(conn, %{"site_id" => site_id}) do
    pending = get_session(conn, :meta_ads_pending_tokens) |> decrypt_session_tokens()
    site_id_int = String.to_integer(site_id)

    if is_map(pending) && (pending["site_id"] || pending[:site_id]) == site_id_int do
      accounts = pending["accounts"] || pending[:accounts] || []
      render(conn, :meta_pick_account, site_id: site_id, accounts: accounts)
    else
      conn
      |> put_flash(:error, "Session expired. Please reconnect Meta Ads.")
      |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
    end
  end

  # User selected a Meta Ads account
  def meta_select_account(conn, %{"site_id" => site_id, "account_id" => account_id}) do
    pending = get_session(conn, :meta_ads_pending_tokens) |> decrypt_session_tokens()
    tokens = normalize_pending(pending)

    if tokens do
      accounts = tokens["accounts"] || []
      selected = Enum.find(accounts, fn a -> (a["id"] || a[:id]) == account_id end)
      name = (selected && (selected["name"] || selected[:name])) || account_id

      merged = %{
        access_token: tokens["access_token"],
        refresh_token: tokens["refresh_token"],
        expires_in: tokens["expires_in"],
        account_id: account_id,
        account_name: name
      }

      conn
      |> delete_session(:meta_ads_pending_tokens)
      |> save_and_redirect("meta_ads", String.to_integer(site_id), merged)
    else
      conn
      |> put_flash(:error, "Session expired. Please reconnect Meta Ads.")
      |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
    end
  end

  # Bing Ads account picker page
  def bing_pick_account(conn, %{"site_id" => site_id}) do
    pending = get_session(conn, :bing_ads_pending_tokens) |> decrypt_session_tokens()
    site_id_int = String.to_integer(site_id)

    if is_map(pending) && (pending["site_id"] || pending[:site_id]) == site_id_int do
      accounts = pending["accounts"] || pending[:accounts] || []
      render(conn, :bing_pick_account, site_id: site_id, accounts: accounts)
    else
      conn
      |> put_flash(:error, "Session expired. Please reconnect Microsoft Ads.")
      |> redirect(to: ~p"/dashboard/sites/#{site_id}/settings")
    end
  end

  # User selected a Bing Ads account
  def bing_select_account(conn, %{"site_id" => site_id, "account_id" => account_id}) do
    pending = get_session(conn, :bing_ads_pending_tokens) |> decrypt_session_tokens()
    tokens = normalize_pending(pending)

    if tokens do
      accounts = tokens["accounts"] || []
      selected = Enum.find(accounts, fn a -> (a["id"] || a[:id]) == account_id end)
      name = (selected && (selected["name"] || selected[:name])) || account_id
      customer_id = selected && (selected["customer_id"] || selected[:customer_id])

      merged = %{
        access_token: tokens["access_token"],
        refresh_token: tokens["refresh_token"],
        expires_in: tokens["expires_in"],
        account_id: account_id,
        account_name: name,
        extra: %{"customer_id" => customer_id}
      }

      conn
      |> delete_session(:bing_ads_pending_tokens)
      |> save_and_redirect("bing_ads", String.to_integer(site_id), merged)
    else
      conn
      |> put_flash(:error, "Session expired. Please reconnect Microsoft Ads.")
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
           account_name: tokens[:account_name] || platform_label(platform),
           extra: tokens[:extra] || %{}
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
