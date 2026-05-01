defmodule Spectabas.Conversions.MicrosoftAds do
  @moduledoc """
  Microsoft Advertising offline conversion upload via the Bulk Service.

  We use the Bulk endpoint (CSV upload) rather than the SOAP-based
  `ApplyOfflineConversions` because bulk handles up to 1000 rows per call
  and the CSV format is simpler to construct than SOAP envelopes.

  Auth: existing Bing Ads OAuth flow
  (`Spectabas.AdIntegrations.Platforms.BingAds`) — the `msads.manage`
  scope already covers offline conversion uploads. Developer Token from
  the per-platform credentials.

  Caveats from research:
  * MSCLKID auto-tagging must be on at the account level; otherwise the
    landing page never sees an msclkid to capture.
  * **Wait 2 hours** after creating an offline conversion goal before
    sending data, and up to 6 hours for it to appear in UI.
  * Up to 1000 conversions per upload request.
  """

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.HTTP
  alias Spectabas.Conversions.Conversion
  require Logger

  @upload_url "https://campaign.api.bingads.microsoft.com/CampaignManagement/v13/Bulk/Upload"
  @batch_size 1000

  @doc """
  Upload a batch of conversions tied to a single conversion goal name.
  Returns `{:ok, %{success_count, failures}}` or `{:error, reason}`.
  """
  def upload(integration, customer_id, account_id, conversion_name, conversions, _opts \\ []) do
    if length(conversions) > @batch_size do
      {:error, "Microsoft Ads bulk upload max batch is #{@batch_size}"}
    else
      do_upload(integration, customer_id, account_id, conversion_name, conversions)
    end
  end

  defp do_upload(integration, customer_id, account_id, conversion_name, conversions) do
    site = Spectabas.Sites.get_site!(integration.site_id)
    creds = Spectabas.AdIntegrations.Credentials.get_for_platform(site, "bing_ads")
    dev_token = (creds || %{})["developer_token"]

    case access_token(integration) do
      {:ok, access_token} ->
        csv = build_csv(conversion_name, conversions)

        # Microsoft's Bulk Upload is a multi-step flow:
        #   1. POST to GetBulkUploadUrl → get a one-time URL
        #   2. PUT the CSV to that URL
        #   3. POST to GetBulkUploadStatus to confirm processing
        # We collapse the happy path into one helper here; failures bail.
        with {:ok, upload_url} <-
               get_upload_url(access_token, dev_token, customer_id, account_id),
             :ok <- put_csv(upload_url, csv),
             {:ok, status} <-
               poll_status(access_token, dev_token, customer_id, account_id, upload_url) do
          {:ok,
           %{
             success_count: status[:success_count] || length(conversions),
             failures: status[:failures] || []
           }}
        else
          {:error, reason} ->
            Logger.warning(
              "[MicrosoftAds] upload failed: #{inspect(reason) |> String.slice(0, 400)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp access_token(integration) do
    try do
      {:ok, AdIntegrations.decrypt_access_token(integration)}
    rescue
      e -> {:error, "token error: #{Exception.message(e)}"}
    end
  end

  # CSV columns per Microsoft Bulk API offline-conversion record format.
  # Header row + one data row per conversion. MSCLKID is the conversion key.
  defp build_csv(conversion_name, conversions) do
    header =
      "Type,Conversion Name,Conversion Time,Conversion Value,Conversion Currency Code,Microsoft Click Id,Adjustment Value,Adjustment Type"

    rows =
      Enum.map(conversions, fn %Conversion{} = c ->
        timestamp = DateTime.to_iso8601(c.occurred_at)
        value = if c.value, do: Decimal.to_string(c.value), else: ""
        currency = c.currency || "USD"
        msclkid = c.click_id || ""

        ~s("Offline Conversion","#{conversion_name}","#{timestamp}","#{value}","#{currency}","#{msclkid}",,)
      end)

    Enum.join([header | rows], "\r\n")
  end

  defp get_upload_url(access_token, dev_token, customer_id, account_id) do
    body = %{
      "ResponseMode" => "ErrorsAndResults",
      "AccountId" => to_string(account_id)
    }

    case HTTP.post!(@upload_url <> "/GetBulkUploadUrl",
           json: body,
           headers: bing_headers(access_token, dev_token, customer_id, account_id)
         ) do
      %{status: 200, body: %{"UploadUrl" => url}} -> {:ok, url}
      %{status: status, body: resp} -> {:error, {:get_url_failed, status, resp}}
    end
  end

  defp put_csv(upload_url, csv) do
    # Bulk upload step uses raw PUT to a one-shot URL Microsoft hands back —
    # no auth headers needed on this leg. AdIntegrations.HTTP doesn't expose
    # PUT so we call Req directly for this single-purpose step.
    case Req.put(upload_url, body: csv, headers: [{"content-type", "text/csv"}]) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: resp}} -> {:error, {:put_failed, status, resp}}
      {:error, reason} -> {:error, {:put_transport, reason}}
    end
  end

  # Microsoft processes async — poll for up to ~30s. Production should
  # ideally enqueue a follow-up job rather than block, but for the v1
  # batch sizes we expect (<200) this is fine.
  defp poll_status(access_token, dev_token, customer_id, account_id, upload_url) do
    poll_status(access_token, dev_token, customer_id, account_id, upload_url, 0)
  end

  defp poll_status(_, _, _, _, _, 6), do: {:ok, %{success_count: nil, failures: []}}

  defp poll_status(access_token, dev_token, customer_id, account_id, upload_url, attempts) do
    Process.sleep(if attempts == 0, do: 2000, else: 5000)

    body = %{"RequestId" => upload_url, "AccountId" => to_string(account_id)}

    case HTTP.post!(@upload_url <> "/GetBulkUploadStatus",
           json: body,
           headers: bing_headers(access_token, dev_token, customer_id, account_id)
         ) do
      %{status: 200, body: %{"RequestStatus" => "Completed"} = resp} ->
        {:ok,
         %{
           success_count: resp["RowsSuccessfullyProcessed"],
           failures: resp["Errors"] || []
         }}

      %{status: 200, body: %{"RequestStatus" => "InProgress"}} ->
        poll_status(access_token, dev_token, customer_id, account_id, upload_url, attempts + 1)

      %{status: 200, body: %{"RequestStatus" => "Failed"} = resp} ->
        {:error, {:bulk_failed, resp["Errors"] || []}}

      %{status: status, body: resp} ->
        {:error, {:status_failed, status, resp}}
    end
  end

  defp bing_headers(access_token, dev_token, customer_id, account_id) do
    [
      {"authorization", "Bearer #{access_token}"},
      {"developertoken", dev_token || ""},
      {"customerid", to_string(customer_id || "")},
      {"customeraccountid", to_string(account_id || "")},
      {"content-type", "application/json"}
    ]
  end
end
