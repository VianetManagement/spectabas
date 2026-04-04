defmodule Spectabas.AdIntegrations.Platforms.GoogleSearchConsole do
  @moduledoc """
  Google Search Console integration — fetches search analytics data
  (queries, impressions, clicks, CTR, position) per page per day.
  """

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.Credentials
  alias Spectabas.ClickHouse

  @auth_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @api_url "https://www.googleapis.com/webmasters/v3"
  @scope "https://www.googleapis.com/auth/webmasters.readonly"

  @doc "Generate OAuth2 authorization URL."
  def authorize_url(site, state) do
    creds = Credentials.get_for_platform(site, "google_search_console")
    client_id = creds["client_id"]
    redirect = "https://www.spectabas.com/auth/ad/google_search_console/callback"

    params =
      URI.encode_query(%{
        client_id: client_id,
        redirect_uri: redirect,
        response_type: "code",
        scope: @scope,
        access_type: "offline",
        prompt: "consent",
        state: state
      })

    "#{@auth_url}?#{params}"
  end

  @doc "Exchange authorization code for tokens."
  def exchange_code(site, code) do
    creds = Credentials.get_for_platform(site, "google_search_console")

    body =
      URI.encode_query(%{
        code: code,
        client_id: creds["client_id"],
        client_secret: creds["client_secret"],
        redirect_uri: "https://www.spectabas.com/auth/ad/google_search_console/callback",
        grant_type: "authorization_code"
      })

    case Req.post(@token_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok,
         %{
           access_token: resp["access_token"],
           refresh_token: resp["refresh_token"],
           expires_in: resp["expires_in"]
         }}

      {:ok, %{status: _, body: resp}} ->
        {:error, resp["error_description"] || "OAuth exchange failed"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Refresh an expired access token."
  def refresh_token(site, refresh_token) do
    creds = Credentials.get_for_platform(site, "google_search_console")

    body =
      URI.encode_query(%{
        refresh_token: refresh_token,
        client_id: creds["client_id"],
        client_secret: creds["client_secret"],
        grant_type: "refresh_token"
      })

    case Req.post(@token_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok,
         %{
           access_token: resp["access_token"],
           expires_in: resp["expires_in"]
         }}

      {:ok, %{body: resp}} ->
        {:error, resp["error_description"] || "Token refresh failed"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Fetch search analytics data for a date.
  Uses the Search Analytics API to get query + page level data.
  """
  def fetch_search_data(integration, site_url, date) do
    access_token = AdIntegrations.decrypt_access_token(integration)
    date_str = Date.to_iso8601(date)

    body =
      Jason.encode!(%{
        startDate: date_str,
        endDate: date_str,
        dimensions: ["query", "page", "country", "device"],
        rowLimit: 25000,
        startRow: 0
      })

    encoded_url = URI.encode(site_url, &URI.char_unreserved?/1)

    case Req.post(
           "#{@api_url}/sites/#{encoded_url}/searchAnalytics/query",
           body: body,
           headers: [
             {"authorization", "Bearer #{access_token}"},
             {"content-type", "application/json"}
           ]
         ) do
      {:ok, %{status: 200, body: %{"rows" => rows}}} ->
        parsed =
          Enum.map(rows, fn row ->
            keys = row["keys"] || []

            %{
              query: Enum.at(keys, 0, ""),
              page: Enum.at(keys, 1, ""),
              country: Enum.at(keys, 2, ""),
              device: Enum.at(keys, 3, ""),
              clicks: row["clicks"] || 0,
              impressions: row["impressions"] || 0,
              ctr: safe_round((row["ctr"] || 0) * 100, 2),
              position: safe_round(row["position"] || 0, 1)
            }
          end)

        {:ok, parsed}

      {:ok, %{status: 200, body: _}} ->
        # No rows key means no data
        {:ok, []}

      {:ok, %{status: 401}} ->
        {:error, :token_expired}

      {:ok, %{status: 403, body: body}} ->
        msg = get_in(body, ["error", "message"]) || "Forbidden"
        {:error, "GSC API: #{msg}"}

      {:ok, %{status: status, body: body}} ->
        msg =
          if is_map(body),
            do: get_in(body, ["error", "message"]) || "HTTP #{status}",
            else: "HTTP #{status}"

        {:error, msg}

      {:error, reason} ->
        {:error, "GSC API error: #{inspect(reason)}"}
    end
  end

  @doc "Sync search data for a date into ClickHouse."
  def sync_search_data(site, integration, date) do
    # The site_url for GSC is the property URL (e.g., "https://www.roommates.com/" or "sc-domain:roommates.com")
    site_url = (integration.extra || %{})["site_url"] || ""

    if site_url == "" do
      Logger.warning("[GSC] No site_url configured for integration #{integration.id}")
      {:error, "No GSC site_url configured"}
    else
      case fetch_search_data(integration, site_url, date) do
        {:ok, []} ->
          Logger.info("[GSC] No search data for #{date}")
          :ok

        {:ok, rows} ->
          ch_rows =
            Enum.map(rows, fn r ->
              %{
                "site_id" => site.id,
                "date" => Date.to_iso8601(date),
                "query" => r.query,
                "page" => r.page,
                "country" => r.country,
                "device" => r.device,
                "source" => "google",
                "clicks" => r.clicks,
                "impressions" => r.impressions,
                "ctr" => r.ctr,
                "position" => r.position,
                "synced_at" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
              }
            end)

          case ClickHouse.insert("search_console", ch_rows) do
            :ok ->
              Logger.info("[GSC] Synced #{length(ch_rows)} rows for #{date}")
              AdIntegrations.mark_synced(integration)
              :ok

            {:error, reason} ->
              Logger.error("[GSC] CH insert failed: #{inspect(reason) |> String.slice(0, 200)}")
              AdIntegrations.mark_error(integration, "ClickHouse insert failed")
              {:error, reason}
          end

        {:error, :token_expired} ->
          {:error, :token_expired}

        {:error, reason} ->
          Logger.warning("[GSC] Fetch failed: #{inspect(reason) |> String.slice(0, 200)}")
          AdIntegrations.mark_error(integration, reason)
          {:error, reason}
      end
    end
  end

  @doc "List available GSC properties for the authenticated user."
  def list_sites(access_token) do
    case Req.get("#{@api_url}/sites",
           headers: [{"authorization", "Bearer #{access_token}"}]
         ) do
      {:ok, %{status: 200, body: %{"siteEntry" => entries}}} ->
        sites =
          Enum.map(entries, fn e ->
            %{url: e["siteUrl"], permission: e["permissionLevel"]}
          end)

        {:ok, sites}

      {:ok, %{status: 200}} ->
        {:ok, []}

      {:ok, %{status: _, body: body}} ->
        {:error, if(is_map(body), do: get_in(body, ["error", "message"]), else: "Failed")}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp safe_round(n, decimals) when is_float(n), do: Float.round(n, decimals)
  defp safe_round(n, _decimals) when is_integer(n), do: n / 1.0
  defp safe_round(_, _), do: 0.0
end
