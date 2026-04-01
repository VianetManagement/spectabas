defmodule Spectabas.AdIntegrations.Platforms.BingAds do
  @moduledoc "Microsoft/Bing Ads integration — OAuth2 and spend data fetching."

  require Logger

  @authorize_url "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
  @token_url "https://login.microsoftonline.com/common/oauth2/v2.0/token"
  @reporting_url "https://reporting.api.bingads.microsoft.com/Reporting/v13/GenerateReport"
  @scope "https://ads.microsoft.com/msads.manage offline_access"

  defp config do
    Application.get_env(:spectabas, :ad_platforms, [])[:bing_ads] || []
  end

  def authorize_url(state) do
    params =
      URI.encode_query(%{
        client_id: config()[:client_id],
        redirect_uri: redirect_uri(),
        response_type: "code",
        scope: @scope,
        state: state
      })

    "#{@authorize_url}?#{params}"
  end

  def exchange_code(code) do
    case Req.post!(@token_url,
           form: [
             code: code,
             client_id: config()[:client_id],
             client_secret: config()[:client_secret],
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

  def refresh_token(refresh_token) do
    case Req.post!(@token_url,
           form: [
             refresh_token: refresh_token,
             client_id: config()[:client_id],
             client_secret: config()[:client_secret],
             grant_type: "refresh_token"
           ]
         ) do
      %{status: 200, body: body} ->
        {:ok, %{access_token: body["access_token"], expires_in: body["expires_in"]}}

      %{body: body} ->
        {:error, body}
    end
  end

  def fetch_daily_spend(integration, %Date{} = date) do
    access_token = Spectabas.AdIntegrations.decrypt_access_token(integration)
    dev_token = config()[:developer_token]
    account_id = integration.account_id
    customer_id = (integration.extra || %{})["customer_id"] || ""

    report_request = %{
      "ReportName" => "CampaignSpend",
      "Format" => "Csv",
      "Aggregation" => "Daily",
      "Columns" => ["TimePeriod", "CampaignId", "CampaignName", "Spend", "Clicks", "Impressions"],
      "Scope" => %{"AccountIds" => [account_id]},
      "Time" => %{
        "CustomDateRangeStart" => date_parts(date),
        "CustomDateRangeEnd" => date_parts(date)
      }
    }

    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"DeveloperToken", dev_token},
      {"AccountId", account_id},
      {"CustomerId", customer_id},
      {"content-type", "application/json"}
    ]

    case Req.post(@reporting_url,
           json: %{"ReportRequest" => report_request},
           headers: headers
         ) do
      {:ok, %{status: 200, body: body}} ->
        rows = parse_bing_response(body)
        {:ok, rows}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[BingAds] API #{status}: #{inspect(body) |> String.slice(0, 300)}")
        {:error, "API error #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp date_parts(%Date{year: y, month: m, day: d}) do
    %{"Year" => y, "Month" => m, "Day" => d}
  end

  defp parse_bing_response(%{"ReportData" => data}) when is_list(data) do
    Enum.map(data, fn row ->
      %{
        campaign_id: to_string(row["CampaignId"] || ""),
        campaign_name: row["CampaignName"] || "",
        spend: parse_decimal(row["Spend"]),
        clicks: parse_int(row["Clicks"]),
        impressions: parse_int(row["Impressions"])
      }
    end)
  end

  defp parse_bing_response(_), do: []

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
    "#{scheme}://#{host}/auth/ad/bing_ads/callback"
  end
end
