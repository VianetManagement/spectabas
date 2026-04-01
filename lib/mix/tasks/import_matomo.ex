defmodule Mix.Tasks.ImportMatomo do
  @moduledoc """
  Import historical Matomo data into Spectabas ClickHouse events.

  Usage:
    mix import_matomo --site-id 4 --matomo-url https://a.roommates.com --matomo-site 2 --token TOKEN --from 2025-03-01 --to 2025-03-01

  For a test run, use --dry-run to see what would be imported without inserting.
  """

  use Mix.Task
  require Logger

  @shortdoc "Import historical data from Matomo API"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse_args(args)
    site_id = opts[:site_id]
    matomo_url = opts[:matomo_url]
    matomo_site = opts[:matomo_site]
    token = opts[:token]
    from = opts[:from]
    to = opts[:to]
    dry_run = opts[:dry_run] || false

    Logger.info("[ImportMatomo] Importing site_id=#{site_id} from #{from} to #{to}")

    dates = date_range(from, to)

    total_events =
      Enum.reduce(dates, 0, fn date, acc ->
        count = import_day(site_id, matomo_url, matomo_site, token, date, dry_run)
        acc + count
      end)

    Logger.info(
      "[ImportMatomo] Done! Imported #{total_events} synthetic events across #{length(dates)} days"
    )
  end

  defp import_day(site_id, matomo_url, matomo_site, token, date, dry_run) do
    date_str = Date.to_iso8601(date)
    Logger.info("[ImportMatomo] Fetching #{date_str}...")

    # Fetch all dimensions from Matomo
    summary = fetch(matomo_url, matomo_site, token, "VisitsSummary.get", date_str)
    pages = fetch_list(matomo_url, matomo_site, token, "Actions.getPageUrls", date_str, 200)
    countries = fetch_list(matomo_url, matomo_site, token, "UserCountry.getCountry", date_str, 50)
    devices = fetch_list(matomo_url, matomo_site, token, "DevicesDetection.getType", date_str, 20)

    browsers =
      fetch_list(matomo_url, matomo_site, token, "DevicesDetection.getBrowsers", date_str, 30)

    os_list =
      fetch_list(matomo_url, matomo_site, token, "DevicesDetection.getOsFamilies", date_str, 20)

    referrers = fetch_list(matomo_url, matomo_site, token, "Referrers.getAll", date_str, 100)

    total_visits = get_int(summary, "nb_visits")
    total_pageviews = get_int(summary, "nb_actions")
    bounce_count = get_int(summary, "bounce_count")
    avg_duration = get_int(summary, "avg_time_on_site")

    if total_visits == 0 do
      Logger.info("[ImportMatomo] #{date_str}: no visits, skipping")
      0
    else
      # Build synthetic events — one per page hit, distributed across the day
      # with realistic dimensions sampled from the Matomo breakdowns
      events =
        build_events(site_id, date, %{
          total_pageviews: total_pageviews,
          total_visits: total_visits,
          bounce_count: bounce_count,
          avg_duration: avg_duration,
          pages: pages,
          countries: countries,
          devices: devices,
          browsers: browsers,
          os_list: os_list,
          referrers: referrers
        })

      if dry_run do
        Logger.info("[ImportMatomo] #{date_str}: would insert #{length(events)} events (dry run)")
      else
        # Insert in batches of 500
        events
        |> Enum.chunk_every(500)
        |> Enum.each(fn batch ->
          case Spectabas.ClickHouse.insert("events", batch) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.error(
                "[ImportMatomo] Insert failed: #{inspect(reason) |> String.slice(0, 200)}"
              )
          end
        end)

        Logger.info("[ImportMatomo] #{date_str}: inserted #{length(events)} events")
      end

      length(events)
    end
  end

  defp build_events(site_id, date, data) do
    # Build weighted distribution pools for random sampling
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

    # Generate one pageview event per page hit, distributed across the day
    pages_with_hits =
      Enum.map(data.pages, fn p ->
        path = get_str(p, "label", "/") |> clean_page_label()
        hits = get_int(p, "nb_hits")
        {path, hits}
      end)

    # Flatten: one entry per hit
    page_hits =
      Enum.flat_map(pages_with_hits, fn {path, hits} ->
        Enum.map(1..max(hits, 1), fn _ -> path end)
      end)

    # Distribute events evenly across the day (00:00 to 23:59)
    total = length(page_hits)
    seconds_per_event = if total > 0, do: div(86400, total), else: 60

    page_hits
    |> Enum.with_index()
    |> Enum.map(fn {url_path, idx} ->
      # Timestamp spread across the day
      seconds = rem(idx * seconds_per_event, 86400)

      timestamp =
        NaiveDateTime.new!(
          date,
          Time.new!(div(seconds, 3600), rem(div(seconds, 60), 60), rem(seconds, 60))
        )
        |> NaiveDateTime.to_string()
        |> String.replace("T", " ")

      # Sample dimensions from weighted pools
      {country_code, country_name} = sample_country(country_pool)
      device_type = sample_single(device_pool)
      browser = sample_single(browser_pool)
      os = sample_single(os_pool)
      referrer = sample_single(referrer_pool)

      # Generate unique IDs
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

  # --- Matomo API helpers ---

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

  # --- Pool/sampling helpers ---

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

  # --- String helpers ---

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
      String.contains?(label, " | ") -> ""
      true -> ""
    end
  end

  defp date_range(from, to) do
    from_date = Date.from_iso8601!(from)
    to_date = Date.from_iso8601!(to)
    Date.range(from_date, to_date) |> Enum.to_list()
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          site_id: :integer,
          matomo_url: :string,
          matomo_site: :integer,
          token: :string,
          from: :string,
          to: :string,
          dry_run: :boolean
        ],
        aliases: [n: :dry_run]
      )

    opts
  end
end
