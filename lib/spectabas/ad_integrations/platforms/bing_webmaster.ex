defmodule Spectabas.AdIntegrations.Platforms.BingWebmaster do
  @moduledoc """
  Bing Webmaster Tools integration — fetches search analytics data
  (queries, impressions, clicks, CTR, position) via the Bing Webmaster API.
  """

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.ClickHouse

  @api_url "https://ssl.bing.com/webmaster/api.svc/json"

  @doc """
  Fetch search analytics data for a date range from Bing Webmaster API.
  Uses the GetQueryStats endpoint.
  """
  def fetch_search_data(integration, site_url, date) do
    api_key = AdIntegrations.decrypt_access_token(integration)
    encoded_url = URI.encode(site_url, &URI.char_unreserved?/1)

    url =
      "#{@api_url}/GetQueryPageStats?apikey=#{api_key}&siteUrl=#{encoded_url}" <>
        "&query=%27%27"

    case Req.get(url) do
      {:ok, %{status: 200, body: %{"d" => data}}} when is_list(data) ->
        date_str = Date.to_iso8601(date)

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

      {:ok, %{status: status}} ->
        {:error, "Bing API HTTP #{status}"}

      {:error, reason} ->
        {:error, "Bing API error: #{inspect(reason)}"}
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
          Logger.info("[Bing] No search data for #{date}")
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

  # Bing returns dates as "/Date(1234567890000)/" format
  defp extract_bing_date(nil), do: ""

  defp extract_bing_date(date_str) when is_binary(date_str) do
    case Regex.run(~r/\/Date\((\d+)\)\//, date_str) do
      [_, ms] ->
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
