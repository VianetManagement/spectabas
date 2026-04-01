defmodule Spectabas.AdIntegrations.Platforms.GoogleAds do
  @moduledoc "Google Ads API integration — OAuth2 and spend data fetching."

  require Logger

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @api_base "https://googleads.googleapis.com/v17"
  @scope "https://www.googleapis.com/auth/adwords"

  alias Spectabas.AdIntegrations.Credentials

  def authorize_url(site, state) do
    creds = Credentials.get_for_platform(site, "google_ads")

    params =
      URI.encode_query(%{
        client_id: creds["client_id"],
        redirect_uri: redirect_uri(),
        response_type: "code",
        scope: @scope,
        access_type: "offline",
        prompt: "consent",
        state: state
      })

    "#{@authorize_url}?#{params}"
  end

  def exchange_code(site, code) do
    creds = Credentials.get_for_platform(site, "google_ads")

    case Req.post!(@token_url,
           form: [
             code: code,
             client_id: creds["client_id"],
             client_secret: creds["client_secret"],
             redirect_uri: redirect_uri(),
             grant_type: "authorization_code"
           ]
         ) do
      %{status: 200, body: body} ->
        {:ok,
         %{
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           expires_in: body["expires_in"]
         }}

      %{body: body} ->
        {:error, body}
    end
  end

  def refresh_token(site, refresh_token) do
    creds = Credentials.get_for_platform(site, "google_ads")

    case Req.post!(@token_url,
           form: [
             refresh_token: refresh_token,
             client_id: creds["client_id"],
             client_secret: creds["client_secret"],
             grant_type: "refresh_token"
           ]
         ) do
      %{status: 200, body: body} ->
        {:ok, %{access_token: body["access_token"], expires_in: body["expires_in"]}}

      %{body: body} ->
        {:error, body}
    end
  end

  def fetch_daily_spend(site, integration, %Date{} = date) do
    access_token = Spectabas.AdIntegrations.decrypt_access_token(integration)
    creds = Credentials.get_for_platform(site, "google_ads")
    dev_token = creds["developer_token"]
    customer_id = integration.account_id |> String.replace("-", "")

    gaql = """
    SELECT campaign.id, campaign.name, metrics.cost_micros, metrics.clicks, metrics.impressions, segments.date
    FROM campaign
    WHERE segments.date = '#{Date.to_iso8601(date)}'
    """

    url = "#{@api_base}/customers/#{customer_id}/googleAds:searchStream"

    case Req.post(url,
           json: %{query: gaql},
           headers: [
             {"authorization", "Bearer #{access_token}"},
             {"developer-token", dev_token}
           ]
         ) do
      {:ok, %{status: 200, body: body}} ->
        rows = parse_google_response(body)
        {:ok, rows}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[GoogleAds] API #{status}: #{inspect(body) |> String.slice(0, 300)}")
        {:error, "API error #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_google_response(body) when is_list(body) do
    Enum.flat_map(body, fn batch ->
      (batch["results"] || [])
      |> Enum.map(fn result ->
        campaign = result["campaign"] || %{}
        metrics = result["metrics"] || %{}

        %{
          campaign_id: to_string(campaign["id"] || ""),
          campaign_name: campaign["name"] || "",
          spend: (metrics["costMicros"] || 0) / 1_000_000,
          clicks: metrics["clicks"] || 0,
          impressions: metrics["impressions"] || 0
        }
      end)
    end)
  end

  defp parse_google_response(_), do: []

  defp redirect_uri do
    host = Application.get_env(:spectabas, SpectabasWeb.Endpoint)[:url][:host] || "localhost"
    scheme = if host == "localhost", do: "http", else: "https"
    "#{scheme}://#{host}/auth/ad/google_ads/callback"
  end
end
