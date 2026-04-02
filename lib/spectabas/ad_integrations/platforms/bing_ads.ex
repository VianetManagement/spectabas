defmodule Spectabas.AdIntegrations.Platforms.BingAds do
  @moduledoc "Microsoft/Bing Ads integration — OAuth2 and spend data fetching."

  require Logger

  @authorize_url "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
  @token_url "https://login.microsoftonline.com/common/oauth2/v2.0/token"
  @reporting_base "https://reporting.api.bingads.microsoft.com/Reporting/v13/GenerateReport"
  @scope "https://ads.microsoft.com/msads.manage offline_access"
  @max_poll_attempts 20
  @poll_interval_ms 5_000

  alias Spectabas.AdIntegrations.Credentials

  def authorize_url(site, state) do
    creds = Credentials.get_for_platform(site, "bing_ads")

    params =
      URI.encode_query(%{
        client_id: creds["client_id"],
        redirect_uri: redirect_uri(),
        response_type: "code",
        scope: @scope,
        state: state
      })

    "#{@authorize_url}?#{params}"
  end

  def exchange_code(site, code) do
    creds = Credentials.get_for_platform(site, "bing_ads")

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
    creds = Credentials.get_for_platform(site, "bing_ads")

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
    creds = Credentials.get_for_platform(site, "bing_ads")
    headers = auth_headers(access_token, creds, integration)

    # Step 1: Submit report request
    report_request = build_report_request(integration.account_id, date)

    case Req.post("#{@reporting_base}/Submit",
           json: %{"ReportRequest" => report_request},
           headers: headers
         ) do
      {:ok, %{status: 200, body: %{"ReportRequestId" => request_id}}} ->
        # Step 2: Poll until ready, then download
        poll_and_download(request_id, headers)

      {:ok, %{status: status, body: body}} ->
        detail = extract_error(body)
        Logger.warning("[BingAds] Submit #{status}: #{detail}")
        {:error, "Bing Ads #{status}: #{String.slice(detail, 0, 120)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp build_report_request(account_id, date) do
    %{
      "ExcludeColumnHeaders" => false,
      "ExcludeReportFooter" => true,
      "ExcludeReportHeader" => true,
      "Format" => "Csv",
      "FormatVersion" => "2.0",
      "ReportName" => "SpectabasSpend",
      "ReturnOnlyCompleteData" => false,
      "Type" => "CampaignPerformanceReportRequest",
      "Aggregation" => "Daily",
      "Columns" => ["TimePeriod", "CampaignId", "CampaignName", "Spend", "Clicks", "Impressions"],
      "Scope" => %{"AccountIds" => [account_id]},
      "Time" => %{
        "CustomDateRangeStart" => date_parts(date),
        "CustomDateRangeEnd" => date_parts(date)
      }
    }
  end

  defp poll_and_download(request_id, headers, attempt \\ 0) do
    if attempt >= @max_poll_attempts do
      {:error, "Bing Ads report timed out after #{@max_poll_attempts} polls"}
    else
      if attempt > 0, do: Process.sleep(@poll_interval_ms)

      case Req.post("#{@reporting_base}/Poll",
             json: %{"ReportRequestId" => request_id},
             headers: headers
           ) do
        {:ok, %{status: 200, body: %{"ReportRequestStatus" => status}}} ->
          case status["Status"] do
            "Success" ->
              download_report(status["ReportDownloadUrl"])

            "Pending" ->
              poll_and_download(request_id, headers, attempt + 1)

            "Error" ->
              {:error, "Bing Ads report failed: #{inspect(status)}"}

            other ->
              Logger.info("[BingAds] Poll status: #{other}, attempt #{attempt}")
              poll_and_download(request_id, headers, attempt + 1)
          end

        {:ok, %{status: status, body: body}} ->
          {:error, "Bing Ads poll #{status}: #{extract_error(body)}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp download_report(nil), do: {:ok, []}

  defp download_report(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: csv_body}} when is_binary(csv_body) ->
        rows = parse_csv(csv_body)
        {:ok, rows}

      {:ok, %{status: status}} ->
        {:error, "Bing Ads download failed: HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp parse_csv(csv) do
    lines = String.split(csv, ~r/\r?\n/, trim: true)

    case lines do
      [header | data_lines] ->
        columns = String.split(header, ",")
        col_idx = fn name -> Enum.find_index(columns, &(&1 == name)) end

        campaign_id_idx = col_idx.("CampaignId")
        campaign_name_idx = col_idx.("CampaignName")
        spend_idx = col_idx.("Spend")
        clicks_idx = col_idx.("Clicks")
        impressions_idx = col_idx.("Impressions")

        Enum.map(data_lines, fn line ->
          fields = String.split(line, ",")

          %{
            campaign_id: at(fields, campaign_id_idx) || "",
            campaign_name: at(fields, campaign_name_idx) || "",
            spend: parse_decimal(at(fields, spend_idx)),
            clicks: parse_int(at(fields, clicks_idx)),
            impressions: parse_int(at(fields, impressions_idx))
          }
        end)

      _ ->
        []
    end
  end

  defp at(_list, nil), do: nil
  defp at(list, idx), do: Enum.at(list, idx)

  defp auth_headers(access_token, creds, integration) do
    customer_id = (integration.extra || %{})["customer_id"] || ""

    [
      {"Authorization", "Bearer #{access_token}"},
      {"DeveloperToken", creds["developer_token"]},
      {"CustomerAccountId", integration.account_id},
      {"CustomerId", customer_id},
      {"Content-Type", "application/json"}
    ]
  end

  defp date_parts(%Date{year: y, month: m, day: d}) do
    %{"Year" => y, "Month" => m, "Day" => d}
  end

  defp extract_error(%{"Message" => msg}), do: msg
  defp extract_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_error(body), do: inspect(body) |> String.slice(0, 200)

  defp parse_decimal(nil), do: 0.0

  defp parse_decimal(n) when is_number(n), do: n

  defp parse_decimal(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_decimal(_), do: 0.0

  defp parse_int(nil), do: 0

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
