defmodule Spectabas.AdIntegrations.Platforms.BingWebmaster do
  @moduledoc """
  Bing Webmaster Tools integration — fetches search analytics data
  (queries, impressions, clicks, CTR, position) via the Bing Webmaster API.
  """

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.HTTP
  alias Spectabas.ClickHouse

  @api_url "https://ssl.bing.com/webmaster/api.svc/json"

  @doc """
  Fetch search analytics data for a date range from Bing Webmaster API.
  Uses the GetQueryStats endpoint.
  """
  def fetch_search_data(integration, site_url, date) do
    api_key = AdIntegrations.decrypt_access_token(integration)
    encoded_url = URI.encode(site_url, &URI.char_unreserved?/1)

    url = "#{@api_url}/GetQueryStats?apikey=#{api_key}&siteUrl=#{encoded_url}"

    case HTTP.get(url) do
      {:ok, %{status: 200, body: %{"d" => data}}} when is_list(data) ->
        date_str = Date.to_iso8601(date)

        # Log sample for debugging
        if length(data) > 0 do
          sample = List.first(data)

          Logger.info(
            "[Bing] API returned #{length(data)} total rows. Sample date: #{inspect(sample["Date"])}, query: #{inspect(sample["Query"])}"
          )
        end

        # Filter to the requested date and parse
        rows =
          data
          |> Enum.filter(fn row ->
            row_date = extract_bing_date(row["Date"])
            row_date == date_str
          end)
          |> Enum.map(fn row ->
            %{
              query: row["Query"] || "",
              page: row["Page"] || "",
              clicks: row["Clicks"] || 0,
              impressions: row["Impressions"] || 0,
              ctr:
                if(row["Impressions"] > 0,
                  do: Float.round(row["Clicks"] / row["Impressions"] * 100, 2),
                  else: 0
                ),
              position: row["AvgClickPosition"] || row["AvgImpressionPosition"] || 0
            }
          end)

        {:ok, rows}

      {:ok, %{status: 200}} ->
        {:ok, []}

      {:ok, %{status: 401}} ->
        {:error, "Invalid Bing Webmaster API key"}

      {:ok, %{status: status, body: body}} ->
        msg = if is_map(body), do: inspect(body) |> String.slice(0, 200), else: "HTTP #{status}"
        {:error, "Bing API HTTP #{status}: #{msg}"}

      {:error, reason} ->
        {:error, "Bing API error: #{inspect(reason)}"}
    end
  end

  @doc "Bulk sync all Bing data into ClickHouse. Fetches once, buckets by date."
  def sync_all_data(site, integration) do
    site_url = (integration.extra || %{})["site_url"] || ""

    if site_url == "" do
      {:error, "No Bing site_url configured"}
    else
      api_key = AdIntegrations.decrypt_access_token(integration)
      encoded_url = URI.encode(site_url, &URI.char_unreserved?/1)

      url = "#{@api_url}/GetQueryStats?apikey=#{api_key}&siteUrl=#{encoded_url}"

      case HTTP.get(url) do
        {:ok, %{status: 200, body: %{"d" => data}}} when is_list(data) ->
          sample = List.first(data)
          sample_keys = if sample, do: Map.keys(sample), else: []
          sample_date = if sample, do: sample["Date"], else: nil

          Logger.info(
            "[Bing] Bulk sync: #{length(data)} rows. Sample keys: #{inspect(sample_keys)}. Sample Date: #{inspect(sample_date)}"
          )

          # Parse all rows and bucket by date
          all_rows =
            Enum.map(data, fn row ->
              %{
                date: extract_bing_date(row["Date"]),
                query: row["Query"] || "",
                page: row["Page"] || "",
                clicks: row["Clicks"] || 0,
                impressions: row["Impressions"] || 0,
                ctr:
                  if(row["Impressions"] > 0,
                    do: Float.round(row["Clicks"] / row["Impressions"] * 100, 2),
                    else: 0
                  ),
                position: row["AvgClickPosition"] || row["AvgImpressionPosition"] || 0
              }
            end)
            |> Enum.reject(fn r -> r.date == "" end)

          rejected = length(data) - length(all_rows)

          if rejected > 0 do
            sample_dates = data |> Enum.take(3) |> Enum.map(& &1["Date"]) |> inspect()

            Logger.warning(
              "[Bing] #{rejected}/#{length(data)} rows rejected (empty date). Sample raw dates: #{sample_dates}"
            )
          end

          if all_rows == [] do
            Logger.warning("[Bing] No parseable rows after date extraction")
            {:ok, 0}
          else
            ch_rows =
              Enum.map(all_rows, fn r ->
                %{
                  "site_id" => site.id,
                  "date" => r.date,
                  "query" => r.query,
                  "page" => r.page,
                  "country" => "",
                  "device" => "",
                  "source" => "bing",
                  "clicks" => r.clicks,
                  "impressions" => r.impressions,
                  "ctr" => r.ctr,
                  "position" => r.position,
                  "synced_at" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
                }
              end)

            case ClickHouse.insert("search_console", ch_rows) do
              :ok ->
                Logger.info("[Bing] Bulk inserted #{length(ch_rows)} rows")
                AdIntegrations.mark_synced(integration)
                {:ok, length(ch_rows)}

              {:error, reason} ->
                Logger.error(
                  "[Bing] CH insert failed: #{inspect(reason) |> String.slice(0, 200)}"
                )

                {:error, reason}
            end
          end

        {:ok, %{status: 200, body: body}} ->
          # Unexpected response structure
          Logger.warning(
            "[Bing] Unexpected 200 body structure: #{inspect(body) |> String.slice(0, 500)}"
          )

          {:error,
           "Unexpected Bing API response format: #{inspect(body) |> String.slice(0, 200)}"}

        {:ok, %{status: status, body: body}} ->
          msg = if is_map(body), do: inspect(body) |> String.slice(0, 200), else: "HTTP #{status}"
          {:error, "Bing API HTTP #{status}: #{msg}"}

        {:error, reason} ->
          {:error, "Bing API error: #{inspect(reason)}"}
      end
    end
  end

  @doc "Sync Bing search data for a date into ClickHouse."
  def sync_search_data(site, integration, date) do
    site_url = (integration.extra || %{})["site_url"] || ""

    if site_url == "" do
      Logger.warning("[Bing] No site_url configured for integration #{integration.id}")
      {:error, "No Bing site_url configured"}
    else
      case fetch_search_data(integration, site_url, date) do
        {:ok, []} ->
          :ok

        {:ok, rows} ->
          ch_rows =
            Enum.map(rows, fn r ->
              %{
                "site_id" => site.id,
                "date" => Date.to_iso8601(date),
                "query" => r.query,
                "page" => r.page,
                "country" => "",
                "device" => "",
                "source" => "bing",
                "clicks" => r.clicks,
                "impressions" => r.impressions,
                "ctr" => r.ctr,
                "position" => r.position,
                "synced_at" => Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
              }
            end)

          date_str = Date.to_iso8601(date)

          ClickHouse.execute(
            "ALTER TABLE search_console DELETE WHERE site_id = #{ClickHouse.param(site.id)} AND date = #{ClickHouse.param(date_str)} AND source = 'bing' SETTINGS mutations_sync = 2"
          )

          case ClickHouse.insert("search_console", ch_rows) do
            :ok ->
              Logger.info("[Bing] Synced #{length(ch_rows)} rows for #{date}")
              AdIntegrations.mark_synced(integration)
              :ok

            {:error, reason} ->
              Logger.error("[Bing] CH insert failed: #{inspect(reason) |> String.slice(0, 200)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.warning("[Bing] Fetch failed: #{inspect(reason)}")
          AdIntegrations.mark_error(integration, reason)
          {:error, reason}
      end
    end
  end

  @doc false
  # Public wrapper for testing. Parses Bing's "/Date(ms)/" format into "YYYY-MM-DD".
  def parse_bing_date(val), do: extract_bing_date(val)

  # Bing returns dates as "/Date(1734681600000-0800)/" — ms since epoch with optional tz offset
  defp extract_bing_date(nil), do: ""

  defp extract_bing_date(date_str) when is_binary(date_str) do
    case Regex.run(~r/\/Date\((\d+)([+-]\d+)?\)\//, date_str) do
      [_, ms | _] ->
        ms
        |> String.to_integer()
        |> div(1000)
        |> DateTime.from_unix!()
        |> DateTime.to_date()
        |> Date.to_iso8601()

      _ ->
        String.slice(date_str, 0, 10)
    end
  end
end
