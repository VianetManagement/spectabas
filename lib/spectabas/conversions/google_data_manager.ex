defmodule Spectabas.Conversions.GoogleDataManager do
  @moduledoc """
  Google Data Manager API client for uploading offline conversions to
  Google Ads. GA as of October 2025; Google's recommended path for new
  builds (deprecating direct Google Ads API ConversionUploadService).

  Request shape:

      POST https://datamanager.googleapis.com/v1/events:ingest
      Authorization: Bearer <access_token>
      Content-Type: application/json

      {
        "destinations": [
          {
            "operatingAccount": {"accountType": "GOOGLE_ADS", "accountId": "1234567890"},
            "loginAccount":     {"accountType": "GOOGLE_ADS", "accountId": "1234567890"},
            "productDestinationId": "<conversion action id>"
          }
        ],
        "encoding": "HEX",
        "events": [...],
        "validateOnly": false
      }

  See `docs/conversions.md` for the full design and event-payload format.

  Note: the access token is obtained via the existing Google Ads OAuth
  flow (`Spectabas.AdIntegrations.Platforms.GoogleAds`). The Data Manager
  scope `https://www.googleapis.com/auth/datamanager` must be added to
  the existing `adwords` scope so re-authorized accounts can call this API.
  """

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.HTTP
  alias Spectabas.Conversions.Conversion
  require Logger

  @endpoint "https://datamanager.googleapis.com/v1/events:ingest"

  @doc """
  Upload a batch of conversions, all targeting the same Google Ads
  customer + conversion action. Returns
  `{:ok, %{request_id, success_count, failures: [...]}}` or
  `{:error, reason}`.
  """
  def upload(
        integration,
        customer_id,
        login_customer_id,
        conversion_action_id,
        conversions,
        opts \\ []
      ) do
    case access_token(integration) do
      {:ok, access_token} ->
        body =
          build_request(customer_id, login_customer_id, conversion_action_id, conversions, opts)

        case HTTP.post!(@endpoint,
               json: body,
               headers: [
                 {"authorization", "Bearer #{access_token}"},
                 {"content-type", "application/json"}
               ]
             ) do
          %{status: 200, body: resp} ->
            {:ok, parse_response(resp, conversions)}

          %{status: status, body: resp} ->
            Logger.warning(
              "[GoogleDataManager] HTTP #{status}: #{inspect(resp) |> String.slice(0, 400)}"
            )

            {:error, {status, resp}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp access_token(integration) do
    # Reuses existing Spectabas.AdIntegrations decryption helper. The token
    # is refreshed lazily by the caller if expired (mirrors fetch_daily_spend).
    try do
      {:ok, AdIntegrations.decrypt_access_token(integration)}
    rescue
      e -> {:error, "token error: #{Exception.message(e)}"}
    end
  end

  defp build_request(customer_id, login_customer_id, conversion_action_id, conversions, opts) do
    %{
      "destinations" => [
        %{
          "operatingAccount" => %{
            "accountType" => "GOOGLE_ADS",
            "accountId" => normalize_id(customer_id)
          },
          "loginAccount" => %{
            "accountType" => "GOOGLE_ADS",
            "accountId" => normalize_id(login_customer_id || customer_id)
          },
          "productDestinationId" => to_string(conversion_action_id)
        }
      ],
      "encoding" => "HEX",
      "events" => Enum.map(conversions, &build_event/1),
      "validateOnly" => Keyword.get(opts, :validate_only, false)
    }
  end

  defp build_event(%Conversion{} = c) do
    base = %{
      "eventTimestamp" => DateTime.to_iso8601(c.occurred_at),
      "transactionId" => "spectabas:#{c.id}",
      "eventSource" => "WEB"
    }

    base
    |> add_value(c)
    |> add_ad_identifier(c)
  end

  defp add_value(event, %Conversion{value: nil}), do: event

  defp add_value(event, %Conversion{value: v} = c) do
    case Decimal.compare(v, 0) do
      :gt ->
        event
        |> Map.put("conversionValue", Decimal.to_float(v))
        |> Map.put("currency", c.currency || "USD")

      _ ->
        event
    end
  end

  # Each conversion sets exactly one click identifier — never multiple.
  # Per Google docs: gclid → adIdentifiers.gclid; wbraid/gbraid use their
  # own keys with a "count: Every" requirement on the conversion action.
  defp add_ad_identifier(event, %Conversion{click_id: nil}), do: event
  defp add_ad_identifier(event, %Conversion{click_id: ""}), do: event

  defp add_ad_identifier(event, %Conversion{click_id_type: type, click_id: cid}) do
    key =
      case type do
        "google_wbraid" -> "wbraid"
        "google_gbraid" -> "gbraid"
        # default — covers "google", "gclid", anything else from older data
        _ -> "gclid"
      end

    Map.put(event, "adIdentifiers", %{key => cid})
  end

  defp normalize_id(id) when is_binary(id), do: String.replace(id, "-", "")
  defp normalize_id(id), do: to_string(id)

  defp parse_response(resp, conversions) when is_map(resp) do
    request_id = resp["requestId"] || ""
    failures = resp["partialFailures"] || resp["failures"] || []

    %{
      request_id: request_id,
      success_count: length(conversions) - length(failures),
      failures: failures
    }
  end

  defp parse_response(_, conversions) do
    %{request_id: "", success_count: length(conversions), failures: []}
  end
end
