defmodule Spectabas.AdIntegrations.Platforms.GoogleAds do
  @moduledoc "Google Ads API integration — OAuth2 and spend data fetching."

  require Logger

  @authorize_url "https://accounts.google.com/o/oauth2/v2/auth"
  @token_url "https://oauth2.googleapis.com/token"
  @api_base "https://googleads.googleapis.com/v23"
  # `adwords` for spend reads + ConversionUploadService legacy fallback.
  # `datamanager` for the Data Manager API used by Conversions.GoogleDataManager
  # (offline conversion uploads). Existing connections will need to be
  # disconnected + reconnected to pick up the new scope.
  @scope "https://www.googleapis.com/auth/adwords https://www.googleapis.com/auth/datamanager"

  alias Spectabas.AdIntegrations.{Credentials, HTTP}

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

    case HTTP.post!(@token_url,
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

    case HTTP.post!(@token_url,
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
    if integration.account_id in [nil, ""] do
      {:error, "No Google Ads customer ID set. Please disconnect and reconnect Google Ads."}
    else
      do_fetch_daily_spend(site, integration, date)
    end
  end

  defp do_fetch_daily_spend(site, integration, date) do
    access_token = Spectabas.AdIntegrations.decrypt_access_token(integration)
    creds = Credentials.get_for_platform(site, "google_ads")
    dev_token = creds["developer_token"]
    customer_id = integration.account_id |> String.replace("-", "")
    login_customer_id = (integration.extra || %{})["login_customer_id"] || customer_id

    gaql =
      "SELECT campaign.id, campaign.name, metrics.cost_micros, metrics.clicks, metrics.impressions, segments.date " <>
        "FROM campaign WHERE segments.date = '#{Date.to_iso8601(date)}'"

    url = "#{@api_base}/customers/#{customer_id}/googleAds:searchStream"

    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"developer-token", dev_token},
      {"login-customer-id", String.replace(login_customer_id, "-", "")}
    ]

    case HTTP.post(url, json: %{query: gaql}, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        rows = parse_google_response(body)
        {:ok, rows}

      {:ok, %{status: status, body: body}} ->
        detail = extract_error_detail(body)
        Logger.warning("[GoogleAds] API #{status}: #{detail}")
        {:error, "Google Ads #{status}: #{String.slice(detail, 0, 120)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp extract_error_detail(%{"error" => %{"message" => msg}}), do: msg

  defp extract_error_detail(body) when is_list(body) do
    body
    |> Enum.find_value(fn
      %{"error" => %{"message" => msg}} -> msg
      _ -> nil
    end) || inspect(body) |> String.slice(0, 200)
  end

  defp extract_error_detail(body), do: inspect(body) |> String.slice(0, 200)

  defp parse_google_response(body) when is_list(body) do
    Enum.flat_map(body, fn batch ->
      (batch["results"] || [])
      |> Enum.map(fn result ->
        campaign = result["campaign"] || %{}
        metrics = result["metrics"] || %{}

        %{
          campaign_id: to_string(campaign["id"] || ""),
          campaign_name: campaign["name"] || "",
          spend: parse_micros(metrics["costMicros"]),
          clicks: parse_int(metrics["clicks"]),
          impressions: parse_int(metrics["impressions"])
        }
      end)
    end)
  end

  defp parse_google_response(_), do: []

  # Google Ads API returns all metric values as strings
  defp parse_micros(nil), do: 0.0
  defp parse_micros(n) when is_integer(n), do: n / 1_000_000

  defp parse_micros(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i / 1_000_000
      :error -> 0.0
    end
  end

  defp parse_micros(_), do: 0.0

  defp parse_int(nil), do: 0
  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp parse_int(_), do: 0

  @doc "Fetch accessible customer IDs after OAuth. Returns list of %{id, descriptive_name}."
  def list_accessible_customers(access_token, developer_token) do
    url = "#{@api_base}/customers:listAccessibleCustomers"

    case HTTP.get(url,
           headers: [
             {"authorization", "Bearer #{access_token}"},
             {"developer-token", developer_token}
           ]
         ) do
      {:ok, %{status: 200, body: %{"resourceNames" => names}}} ->
        customers =
          names
          |> Enum.map(fn name ->
            id = String.replace_prefix(name, "customers/", "")
            descriptive = fetch_customer_name(id, access_token, developer_token)
            %{id: id, name: descriptive || id}
          end)
          |> Enum.reject(&(&1.name == ""))

        {:ok, customers}

      {:ok, %{status: status, body: body}} ->
        {:error, "Google Ads #{status}: #{extract_error_detail(body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp fetch_customer_name(customer_id, access_token, developer_token) do
    url = "#{@api_base}/customers/#{customer_id}/googleAds:searchStream"

    case HTTP.post(url,
           json: %{query: "SELECT customer.id, customer.descriptive_name FROM customer LIMIT 1"},
           headers: [
             {"authorization", "Bearer #{access_token}"},
             {"developer-token", developer_token},
             {"login-customer-id", customer_id}
           ]
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        body
        |> Enum.find_value(fn batch ->
          batch
          |> Map.get("results", [])
          |> Enum.find_value(fn r -> get_in(r, ["customer", "descriptiveName"]) end)
        end)

      _ ->
        nil
    end
  end

  defp redirect_uri do
    host = Application.get_env(:spectabas, SpectabasWeb.Endpoint)[:url][:host] || "localhost"
    scheme = if host == "localhost", do: "http", else: "https"
    "#{scheme}://#{host}/auth/ad/google_ads/callback"
  end
end
