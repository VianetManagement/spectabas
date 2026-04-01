defmodule Spectabas.Imports.Matomo do
  @moduledoc """
  Import historical Matomo data into ClickHouse rollup tables.
  Writes to imported_daily_stats, imported_pages, imported_sources,
  imported_countries, and imported_devices — NOT the raw events table.
  """

  require Logger

  alias Spectabas.ClickHouse

  @imported_tables ~w(imported_daily_stats imported_pages imported_sources imported_countries imported_devices)

  @doc "Import a single day of Matomo data into rollup tables."
  def import_day(site_id, matomo_url, matomo_site_id, token, %Date{} = date) do
    date_str = Date.to_iso8601(date)
    Logger.info("[MatomoImport] Fetching #{date_str}...")

    summary = fetch(matomo_url, matomo_site_id, token, "VisitsSummary.get", date_str)
    visits = get_int(summary, "nb_visits")

    if visits == 0 do
      Logger.info("[MatomoImport] #{date_str}: no visits, skipping")
      {:ok, 0}
    else
      # 1. Daily summary
      ClickHouse.insert("imported_daily_stats", [
        %{
          "site_id" => site_id,
          "date" => date_str,
          "pageviews" => get_int(summary, "nb_actions"),
          "visitors" => get_int(summary, "nb_uniq_visitors"),
          "sessions" => visits,
          "bounces" => get_int(summary, "bounce_count"),
          "total_duration" => get_int(summary, "sum_visit_length")
        }
      ])

      # 2. Pages
      pages = fetch_list(matomo_url, matomo_site_id, token, "Actions.getPageUrls", date_str, 200)

      page_rows =
        Enum.map(pages, fn p ->
          %{
            "site_id" => site_id,
            "date" => date_str,
            "url_path" => clean_page_label(get_str(p, "label")),
            "pageviews" => get_int(p, "nb_hits"),
            "visitors" => get_int(p, "nb_visits")
          }
        end)
        |> Enum.reject(&(&1["url_path"] == ""))

      if page_rows != [], do: ClickHouse.insert("imported_pages", page_rows)

      # 3. Countries
      countries =
        fetch_list(matomo_url, matomo_site_id, token, "UserCountry.getCountry", date_str, 50)

      country_rows =
        Enum.map(countries, fn c ->
          %{
            "site_id" => site_id,
            "date" => date_str,
            "ip_country" => String.upcase(get_str(c, "code")),
            "ip_country_name" => get_str(c, "label"),
            "pageviews" => get_int(c, "nb_visits"),
            "visitors" => get_int(c, "nb_uniq_visitors")
          }
        end)
        |> Enum.reject(&(&1["ip_country"] == ""))

      if country_rows != [], do: ClickHouse.insert("imported_countries", country_rows)

      # 4. Devices (type, browser, os as separate inserts)
      devices =
        fetch_list(matomo_url, matomo_site_id, token, "DevicesDetection.getType", date_str, 20)

      device_rows =
        Enum.map(devices, fn d ->
          %{
            "site_id" => site_id,
            "date" => date_str,
            "device_type" => normalize_device(get_str(d, "label")),
            "browser" => "",
            "os" => "",
            "pageviews" => get_int(d, "nb_visits"),
            "visitors" => get_int(d, "nb_uniq_visitors")
          }
        end)
        |> Enum.reject(&(&1["device_type"] == ""))

      browsers =
        fetch_list(
          matomo_url,
          matomo_site_id,
          token,
          "DevicesDetection.getBrowsers",
          date_str,
          30
        )

      browser_rows =
        Enum.map(browsers, fn b ->
          %{
            "site_id" => site_id,
            "date" => date_str,
            "device_type" => "",
            "browser" => get_str(b, "label"),
            "os" => "",
            "pageviews" => get_int(b, "nb_visits"),
            "visitors" => get_int(b, "nb_uniq_visitors")
          }
        end)
        |> Enum.reject(&(&1["browser"] == ""))

      os_list =
        fetch_list(
          matomo_url,
          matomo_site_id,
          token,
          "DevicesDetection.getOsFamilies",
          date_str,
          20
        )

      os_rows =
        Enum.map(os_list, fn o ->
          %{
            "site_id" => site_id,
            "date" => date_str,
            "device_type" => "",
            "browser" => "",
            "os" => get_str(o, "label"),
            "pageviews" => get_int(o, "nb_visits"),
            "visitors" => get_int(o, "nb_uniq_visitors")
          }
        end)
        |> Enum.reject(&(&1["os"] == ""))

      all_device_rows = device_rows ++ browser_rows ++ os_rows
      if all_device_rows != [], do: ClickHouse.insert("imported_devices", all_device_rows)

      # 5. Sources/referrers
      referrers =
        fetch_list(matomo_url, matomo_site_id, token, "Referrers.getAll", date_str, 100)

      source_rows =
        Enum.map(referrers, fn r ->
          %{
            "site_id" => site_id,
            "date" => date_str,
            "referrer_domain" => normalize_referrer(get_str(r, "label")),
            "utm_source" => "",
            "utm_medium" => "",
            "pageviews" => get_int(r, "nb_actions"),
            "sessions" => get_int(r, "nb_visits"),
            "visitors" => get_int(r, "nb_visits")
          }
        end)
        |> Enum.reject(&(&1["referrer_domain"] == ""))

      if source_rows != [], do: ClickHouse.insert("imported_sources", source_rows)

      Logger.info("[MatomoImport] #{date_str}: imported (#{visits} visits)")
      {:ok, 1}
    end
  rescue
    e ->
      Logger.error("[MatomoImport] #{date} crashed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "Import a date range. Returns {:ok, days_imported, total_days}."
  def import_range(site_id, matomo_url, matomo_site_id, token, from_date, to_date) do
    dates = Date.range(from_date, to_date) |> Enum.to_list()

    imported =
      Enum.reduce(dates, 0, fn date, acc ->
        case import_day(site_id, matomo_url, matomo_site_id, token, date) do
          {:ok, n} -> acc + n
          _ -> acc
        end
      end)

    {:ok, imported, length(dates)}
  end

  @doc "Delete all imported data for a site from all rollup tables."
  def rollback(site_id) do
    db = ClickHouse.database()

    results =
      Enum.map(@imported_tables, fn table ->
        sql = "ALTER TABLE #{db}.#{table} DELETE WHERE site_id = #{ClickHouse.param(site_id)}"

        case ClickHouse.execute(sql) do
          :ok -> {table, :ok}
          {:error, reason} -> {table, {:error, reason}}
        end
      end)

    Logger.info("[MatomoImport] Rollback for site #{site_id}: #{inspect(results)}")
    {:ok, results}
  end

  @doc "Count imported days for a site."
  def imported_day_count(site_id) do
    sql =
      "SELECT count() AS c FROM imported_daily_stats WHERE site_id = #{ClickHouse.param(site_id)}"

    case ClickHouse.query(sql) do
      {:ok, [%{"c" => c}]} -> Spectabas.TypeHelpers.to_num(c)
      _ -> 0
    end
  end

  # --- Matomo API ---

  defp fetch(matomo_url, site_id, token, method, date) do
    body =
      "module=API&method=#{method}&idSite=#{site_id}&period=day&date=#{date}&format=json&token_auth=#{token}"

    case Req.post!(matomo_url <> "/index.php",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      %{status: 200, body: body} when is_map(body) -> body
      %{status: 200, body: [item | _]} when is_map(item) -> item
      _ -> %{}
    end
  end

  defp fetch_list(matomo_url, site_id, token, method, date, limit) do
    body =
      "module=API&method=#{method}&idSite=#{site_id}&period=day&date=#{date}&format=json&token_auth=#{token}&flat=1&filter_limit=#{limit}&filter_sort_column=nb_visits&filter_sort_order=desc"

    case Req.post!(matomo_url <> "/index.php",
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      %{status: 200, body: body} when is_list(body) -> body
      _ -> []
    end
  end

  # --- Helpers ---

  defp get_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      s when is_binary(s) -> String.to_integer(s)
      _ -> 0
    end
  end

  defp get_str(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) and s != "" -> s
      _ -> ""
    end
  end

  defp clean_page_label(label) do
    label
    |> String.split(" - Others")
    |> List.first()
    |> String.split("?")
    |> List.first()
    |> then(fn
      "/" <> _ = path -> path
      "" -> ""
      path -> "/" <> path
    end)
  end

  defp normalize_device("Smartphone"), do: "smartphone"
  defp normalize_device("Desktop"), do: "desktop"
  defp normalize_device("Tablet"), do: "tablet"
  defp normalize_device("Phablet"), do: "smartphone"
  defp normalize_device(other), do: String.downcase(other)

  defp normalize_referrer(""), do: ""

  defp normalize_referrer(label) do
    if String.contains?(label, "."), do: label, else: ""
  end
end
