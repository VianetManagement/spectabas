defmodule Spectabas.Imports.Matomo do
  @moduledoc """
  Import historical Matomo data into ClickHouse events table.
  Fetches daily aggregates from Matomo API and generates synthetic pageview events.
  """

  require Logger

  @doc """
  Import a single day of Matomo data for the given site.
  Returns {:ok, count} or {:error, reason}.
  """
  def import_day(site_id, matomo_url, matomo_site_id, token, %Date{} = date) do
    date_str = Date.to_iso8601(date)
    Logger.info("[MatomoImport] Fetching #{date_str}...")

    summary = fetch(matomo_url, matomo_site_id, token, "VisitsSummary.get", date_str)
    total_visits = get_int(summary, "nb_visits")

    if total_visits == 0 do
      Logger.info("[MatomoImport] #{date_str}: no visits, skipping")
      {:ok, 0}
    else
      pages = fetch_list(matomo_url, matomo_site_id, token, "Actions.getPageUrls", date_str, 200)

      countries =
        fetch_list(matomo_url, matomo_site_id, token, "UserCountry.getCountry", date_str, 50)

      devices =
        fetch_list(matomo_url, matomo_site_id, token, "DevicesDetection.getType", date_str, 20)

      browsers =
        fetch_list(
          matomo_url,
          matomo_site_id,
          token,
          "DevicesDetection.getBrowsers",
          date_str,
          30
        )

      os_list =
        fetch_list(
          matomo_url,
          matomo_site_id,
          token,
          "DevicesDetection.getOsFamilies",
          date_str,
          20
        )

      referrers =
        fetch_list(matomo_url, matomo_site_id, token, "Referrers.getAll", date_str, 100)

      events =
        build_events(site_id, date, %{
          pages: pages,
          countries: countries,
          devices: devices,
          browsers: browsers,
          os_list: os_list,
          referrers: referrers
        })

      errors =
        events
        |> Enum.chunk_every(500)
        |> Enum.reduce(0, fn batch, err_count ->
          case Spectabas.ClickHouse.insert("events", batch) do
            :ok ->
              err_count

            {:error, reason} ->
              Logger.error(
                "[MatomoImport] Insert failed: #{inspect(reason) |> String.slice(0, 200)}"
              )

              err_count + 1
          end
        end)

      count = length(events)
      Logger.info("[MatomoImport] #{date_str}: inserted #{count} events (#{errors} batch errors)")
      {:ok, count}
    end
  rescue
    e ->
      Logger.error("[MatomoImport] Crashed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc "Import a date range. Returns total event count."
  def import_range(site_id, matomo_url, matomo_site_id, token, from_date, to_date) do
    dates = Date.range(from_date, to_date) |> Enum.to_list()

    total =
      Enum.reduce(dates, 0, fn date, acc ->
        case import_day(site_id, matomo_url, matomo_site_id, token, date) do
          {:ok, count} -> acc + count
          _ -> acc
        end
      end)

    {:ok, total, length(dates)}
  end

  @doc "Delete all imported events for a site. Returns {:ok, count} or {:error, reason}."
  def rollback(site_id) do
    Logger.info("[MatomoImport] Rolling back imported data for site #{site_id}...")

    # Count first
    count_sql =
      "SELECT count() AS c FROM events WHERE site_id = #{Spectabas.ClickHouse.param(site_id)} AND visitor_id LIKE 'imported\\_%'"

    count =
      case Spectabas.ClickHouse.query(count_sql) do
        {:ok, [%{"c" => c}]} -> Spectabas.TypeHelpers.to_num(c)
        _ -> 0
      end

    if count == 0 do
      Logger.info("[MatomoImport] No imported data found for site #{site_id}")
      {:ok, 0}
    else
      # Delete imported events using ALTER TABLE DELETE
      delete_sql =
        "ALTER TABLE #{Spectabas.ClickHouse.database()}.events DELETE WHERE site_id = #{Spectabas.ClickHouse.param(site_id)} AND visitor_id LIKE 'imported\\_%'"

      case Spectabas.ClickHouse.execute(delete_sql) do
        :ok ->
          Logger.info("[MatomoImport] Rolled back #{count} imported events for site #{site_id}")
          {:ok, count}

        {:error, reason} ->
          Logger.error("[MatomoImport] Rollback failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc "Count imported events for a site."
  def imported_count(site_id) do
    sql =
      "SELECT count() AS c FROM events WHERE site_id = #{Spectabas.ClickHouse.param(site_id)} AND visitor_id LIKE 'imported\\_%'"

    case Spectabas.ClickHouse.query(sql) do
      {:ok, [%{"c" => c}]} -> Spectabas.TypeHelpers.to_num(c)
      _ -> 0
    end
  end

  # --- Event generation ---

  defp build_events(site_id, date, data) do
    country_pool =
      build_pool(data.countries, fn c ->
        {get_str(c, "code", ""), get_str(c, "label", ""), get_int(c, "nb_visits")}
      end)

    device_pool =
      build_pool(data.devices, fn d ->
        {normalize_device(get_str(d, "label", "")), get_int(d, "nb_visits")}
      end)

    browser_pool =
      build_pool(data.browsers, fn b -> {get_str(b, "label", ""), get_int(b, "nb_visits")} end)

    os_pool =
      build_pool(data.os_list, fn o -> {get_str(o, "label", ""), get_int(o, "nb_visits")} end)

    referrer_pool =
      build_pool(data.referrers, fn r -> {get_str(r, "label", ""), get_int(r, "nb_visits")} end)

    page_hits =
      data.pages
      |> Enum.flat_map(fn p ->
        path = get_str(p, "label", "/") |> clean_page_label()
        hits = get_int(p, "nb_hits")
        Enum.map(1..max(hits, 1), fn _ -> path end)
      end)

    total = length(page_hits)
    seconds_per_event = if total > 0, do: div(86400, total), else: 60

    page_hits
    |> Enum.with_index()
    |> Enum.map(fn {url_path, idx} ->
      seconds = rem(idx * seconds_per_event, 86400)

      timestamp =
        NaiveDateTime.new!(
          date,
          Time.new!(div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60))
        )
        |> NaiveDateTime.to_string()
        |> String.replace("T", " ")

      {country_code, country_name} = sample_country(country_pool)
      device_type = sample_single(device_pool)
      browser = sample_single(browser_pool)
      os = sample_single(os_pool)
      referrer = sample_single(referrer_pool)

      visitor_id = "imported_#{:erlang.phash2({site_id, date, idx}, 4_294_967_296)}"
      session_id = "imported_s_#{:erlang.phash2({site_id, date, idx, url_path}, 4_294_967_296)}"

      %{
        "event_id" => Ecto.UUID.generate(),
        "site_id" => site_id,
        "visitor_id" => visitor_id,
        "session_id" => session_id,
        "event_type" => "pageview",
        "event_name" => "",
        "url_path" => url_path,
        "url_host" => "www.roommates.com",
        "referrer_domain" => normalize_referrer(referrer),
        "referrer_url" => "",
        "utm_source" => "",
        "utm_medium" => "",
        "utm_campaign" => "",
        "utm_term" => "",
        "utm_content" => "",
        "device_type" => device_type,
        "browser" => browser,
        "browser_version" => "",
        "os" => os,
        "os_version" => "",
        "screen_width" => 0,
        "screen_height" => 0,
        "ip_address" => "",
        "ip_country" => String.upcase(country_code),
        "ip_country_name" => country_name,
        "ip_continent" => "",
        "ip_continent_name" => "",
        "ip_region_code" => "",
        "ip_region_name" => "",
        "ip_city" => "",
        "ip_postal_code" => "",
        "ip_lat" => 0.0,
        "ip_lon" => 0.0,
        "ip_accuracy_radius" => 0,
        "ip_timezone" => "",
        "ip_asn" => 0,
        "ip_asn_org" => "",
        "ip_org" => "",
        "ip_is_datacenter" => 0,
        "ip_is_vpn" => 0,
        "ip_is_tor" => 0,
        "ip_is_bot" => 0,
        "ip_is_eu" => 0,
        "ip_gdpr_anonymized" => 0,
        "visitor_intent" => "",
        "user_agent" => "",
        "browser_fingerprint" => "",
        "duration_s" => 0,
        "properties" => "{}",
        "is_bounce" => 1,
        "timestamp" => timestamp
      }
    end)
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

  defp build_pool(items, mapper) do
    items
    |> Enum.map(mapper)
    |> Enum.reject(fn tuple -> elem(tuple, tuple_size(tuple) - 1) <= 0 end)
  end

  defp sample_country([]), do: {"", ""}

  defp sample_country(pool) do
    total = Enum.sum(Enum.map(pool, fn {_, _, w} -> w end))
    r = :rand.uniform(total)
    pick_weighted(pool, r, fn {code, name, w} -> {w, {code, name}} end)
  end

  defp sample_single([]), do: ""

  defp sample_single(pool) do
    total = Enum.sum(Enum.map(pool, fn {_, w} -> w end))
    r = :rand.uniform(total)
    pick_weighted(pool, r, fn {label, w} -> {w, label} end)
  end

  defp pick_weighted([], _, _), do: ""

  defp pick_weighted([item | rest], remaining, extractor) do
    {weight, value} = extractor.(item)
    if remaining <= weight, do: value, else: pick_weighted(rest, remaining - weight, extractor)
  end

  defp get_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      s when is_binary(s) -> String.to_integer(s)
      _ -> 0
    end
  end

  defp get_str(map, key, default) do
    case Map.get(map, key) do
      s when is_binary(s) and s != "" -> s
      _ -> default
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
    cond do
      String.contains?(label, ".") -> label
      true -> ""
    end
  end
end
