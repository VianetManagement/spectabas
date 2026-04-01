defmodule Spectabas.AdIntegrations.Platforms.MetaAds do
  @moduledoc "Facebook/Meta Ads integration — OAuth2 and spend data fetching."

  require Logger

  @graph_url "https://graph.facebook.com/v21.0"
  @authorize_url "https://www.facebook.com/v21.0/dialog/oauth"

  defp config do
    Application.get_env(:spectabas, :ad_platforms, [])[:meta_ads] || []
  end

  def authorize_url(state) do
    params =
      URI.encode_query(%{
        client_id: config()[:app_id],
        redirect_uri: redirect_uri(),
        response_type: "code",
        scope: "ads_read",
        state: state
      })

    "#{@authorize_url}?#{params}"
  end

  def exchange_code(code) do
    # Get short-lived token
    case Req.get!("#{@graph_url}/oauth/access_token",
           params: [
             client_id: config()[:app_id],
             client_secret: config()[:app_secret],
             redirect_uri: redirect_uri(),
             code: code
           ]
         ) do
      %{status: 200, body: %{"access_token" => short_token}} ->
        # Exchange for long-lived token (60 days)
        case Req.get!("#{@graph_url}/oauth/access_token",
               params: [
                 grant_type: "fb_exchange_token",
                 client_id: config()[:app_id],
                 client_secret: config()[:app_secret],
                 fb_exchange_token: short_token
               ]
             ) do
          %{status: 200, body: body} ->
            {:ok,
             %{
               access_token: body["access_token"],
               refresh_token: body["access_token"],
               expires_in: body["expires_in"] || 5_184_000
             }}

          %{body: body} ->
            {:error, body}
        end

      %{body: body} ->
        {:error, body}
    end
  end

  def refresh_token(current_token) do
    # Meta long-lived tokens are refreshed by exchanging again
    case Req.get!("#{@graph_url}/oauth/access_token",
           params: [
             grant_type: "fb_exchange_token",
             client_id: config()[:app_id],
             client_secret: config()[:app_secret],
             fb_exchange_token: current_token
           ]
         ) do
      %{status: 200, body: body} ->
        {:ok,
         %{
           access_token: body["access_token"],
           expires_in: body["expires_in"] || 5_184_000
         }}

      %{body: body} ->
        {:error, body}
    end
  end

  def fetch_ad_accounts(access_token) do
    case Req.get("#{@graph_url}/me/adaccounts",
           params: [fields: "account_id,name,currency", access_token: access_token]
         ) do
      {:ok, %{status: 200, body: %{"data" => accounts}}} ->
        {:ok,
         Enum.map(accounts, fn a ->
           %{id: a["account_id"], name: a["name"], currency: a["currency"]}
         end)}

      {:ok, %{body: body}} ->
        {:error, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def fetch_daily_spend(integration, %Date{} = date) do
    access_token = Spectabas.AdIntegrations.decrypt_access_token(integration)
    account_id = integration.account_id
    date_str = Date.to_iso8601(date)

    url = "#{@graph_url}/act_#{account_id}/insights"

    case Req.get(url,
           params: [
             fields: "campaign_id,campaign_name,spend,clicks,impressions",
             time_range: Jason.encode!(%{since: date_str, until: date_str}),
             level: "campaign",
             limit: 500,
             access_token: access_token
           ]
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        rows =
          Enum.map(data, fn row ->
            %{
              campaign_id: row["campaign_id"] || "",
              campaign_name: row["campaign_name"] || "",
              spend: parse_decimal(row["spend"]),
              clicks: parse_int(row["clicks"]),
              impressions: parse_int(row["impressions"])
            }
          end)

        {:ok, rows}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[MetaAds] API #{status}: #{inspect(body) |> String.slice(0, 300)}")
        {:error, "API error #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_decimal(n) when is_number(n), do: n

  defp parse_decimal(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp parse_decimal(_), do: 0

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  defp redirect_uri do
    host = Application.get_env(:spectabas, SpectabasWeb.Endpoint)[:url][:host] || "localhost"
    scheme = if host == "localhost", do: "http", else: "https"
    "#{scheme}://#{host}/auth/ad/meta_ads/callback"
  end
end
