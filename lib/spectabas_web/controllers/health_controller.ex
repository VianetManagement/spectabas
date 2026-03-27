defmodule SpectabasWeb.HealthController do
  use SpectabasWeb, :controller

  def show(conn, _params) do
    case Spectabas.Health.check() do
      :ok ->
        conn
        |> put_status(200)
        |> json(%{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(503)
        |> json(%{status: "error", reason: reason})
    end
  end

  def diag(conn, _params) do
    results = %{
      clickhouse_process: Process.whereis(Spectabas.ClickHouse) != nil,
      ingest_buffer_process: Process.whereis(Spectabas.Events.IngestBuffer) != nil,
      clickhouse_ping: test_clickhouse_ping(),
      clickhouse_tables: test_clickhouse_tables(),
      clickhouse_events_count: test_clickhouse_count(),
      clickhouse_events_by_site: test_events_by_site(),
      clickhouse_sample_event: test_sample_event(),
      top_pages_query: test_top_pages(),
      sites: test_sites(),
      write_test: test_write(),
      geoip_status: test_geoip(),
      geo_sample: test_geo_sample()
    }

    json(conn, results)
  end

  defp test_clickhouse_ping do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SELECT 1 AS ok") do
        {:ok, _} -> "ok"
        {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_clickhouse_tables do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SHOW TABLES") do
        {:ok, rows} -> Enum.map(rows, & &1["name"])
        {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_clickhouse_count do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SELECT count() AS c FROM events") do
        {:ok, [%{"c" => c}]} -> c
        {:ok, _} -> 0
        {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_top_pages do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query(
             "SELECT url_path, count() AS views FROM events WHERE site_id = 1 AND event_type = 'pageview' GROUP BY url_path ORDER BY views DESC LIMIT 5"
           ) do
        {:ok, rows} -> rows
        {:error, e} -> "error: #{String.slice(to_string(e), 0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_sample_event do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query(
             "SELECT site_id, event_type, visitor_id, session_id, url_path, timestamp FROM events WHERE event_type = 'pageview' ORDER BY timestamp DESC LIMIT 1"
           ) do
        {:ok, [row]} -> row
        {:ok, []} -> "no events"
        {:error, e} -> "error: #{String.slice(to_string(e), 0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_events_by_site do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query(
             "SELECT site_id, event_type, count() AS c FROM events GROUP BY site_id, event_type ORDER BY c DESC LIMIT 10"
           ) do
        {:ok, rows} -> rows
        {:error, e} -> "error: #{String.slice(to_string(e), 0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_write do
    if Process.whereis(Spectabas.ClickHouse) do
      row = %{
        "site_id" => 0,
        "visitor_id" => "diag_test",
        "session_id" => "diag_test",
        "event_type" => "diag",
        "event_name" => "",
        "url_path" => "/diag",
        "url_host" => "test",
        "referrer_domain" => "",
        "referrer_url" => "",
        "utm_source" => "",
        "utm_medium" => "",
        "utm_campaign" => "",
        "utm_term" => "",
        "utm_content" => "",
        "device_type" => "",
        "browser" => "",
        "browser_version" => "",
        "os" => "",
        "os_version" => "",
        "screen_width" => 0,
        "screen_height" => 0,
        "duration_s" => 0,
        "ip_address" => "",
        "ip_country" => "",
        "ip_country_name" => "",
        "ip_continent" => "",
        "ip_continent_name" => "",
        "ip_region_code" => "",
        "ip_region_name" => "",
        "ip_city" => "",
        "ip_postal_code" => "",
        "ip_lat" => 0,
        "ip_lon" => 0,
        "ip_accuracy_radius" => 0,
        "ip_timezone" => "",
        "ip_asn" => 0,
        "ip_asn_org" => "",
        "ip_org" => "",
        "ip_is_datacenter" => 0,
        "ip_is_vpn" => 0,
        "ip_is_tor" => 0,
        "ip_is_bot" => 0,
        "ip_gdpr_anonymized" => 0,
        "properties" => "{}"
      }

      case Spectabas.ClickHouse.insert("events", [row]) do
        :ok -> "ok"
        {:error, e} -> "error: #{String.slice(to_string(e), 0, 300)}"
      end
    else
      "not_started"
    end
  end

  def backfill_geo(conn, _params) do
    # Run inline instead of via Oban so we see immediate results
    alias Spectabas.ClickHouse

    # Step 1: Find IPs needing enrichment
    {:ok, rows} =
      ClickHouse.query(
        "SELECT DISTINCT ip_address FROM events WHERE ip_country = '' AND ip_address != ''"
      )

    ips = Enum.map(rows, & &1["ip_address"])

    # Step 2: Look up each IP and build updates
    results =
      Enum.map(ips, fn ip_str ->
        {:ok, parsed} = :inet.parse_address(String.to_charlist(ip_str))
        city = Geolix.lookup(parsed, where: :city)
        asn = Geolix.lookup(parsed, where: :asn)

        country =
          case city do
            %{country: %{iso_code: c}} -> c
            _ -> nil
          end

        if country do
          country_name =
            case city do
              %{country: %{names: %{"en" => n}}} -> n
              _ -> ""
            end

          continent =
            case city do
              %{continent: %{code: c}} -> c
              _ -> ""
            end

          continent_name =
            case city do
              %{continent: %{names: %{"en" => n}}} -> n
              _ -> ""
            end

          region_code =
            case city do
              %{subdivisions: [%{iso_code: c} | _]} -> c || ""
              _ -> ""
            end

          region_name =
            case city do
              %{subdivisions: [%{names: %{"en" => n}} | _]} -> n
              _ -> ""
            end

          city_name =
            case city do
              %{city: %{names: %{"en" => n}}} -> n
              _ -> ""
            end

          lat =
            case city do
              %{location: %{latitude: l}} -> l
              _ -> 0.0
            end

          lon =
            case city do
              %{location: %{longitude: l}} -> l
              _ -> 0.0
            end

          tz =
            case city do
              %{location: %{time_zone: t}} -> t || ""
              _ -> ""
            end

          asn_num =
            case asn do
              %{autonomous_system_number: n} -> n || 0
              _ -> 0
            end

          asn_org =
            case asn do
              %{autonomous_system_organization: o} -> o || ""
              _ -> ""
            end

          sql = """
          ALTER TABLE events UPDATE
            ip_country = #{ClickHouse.param(country)},
            ip_country_name = #{ClickHouse.param(country_name)},
            ip_continent = #{ClickHouse.param(continent)},
            ip_continent_name = #{ClickHouse.param(continent_name)},
            ip_region_code = #{ClickHouse.param(region_code)},
            ip_region_name = #{ClickHouse.param(region_name)},
            ip_city = #{ClickHouse.param(city_name)},
            ip_lat = #{lat},
            ip_lon = #{lon},
            ip_timezone = #{ClickHouse.param(tz)},
            ip_asn = #{asn_num},
            ip_asn_org = #{ClickHouse.param(asn_org)},
            ip_org = #{ClickHouse.param(if(asn_num > 0, do: "AS#{asn_num} #{asn_org}", else: ""))}
          WHERE ip_address = #{ClickHouse.param(ip_str)}
            AND ip_country = ''
          """

          result = ClickHouse.execute(sql)

          %{
            ip: ip_str,
            country: country,
            region: region_name,
            city: city_name,
            result: inspect(result)
          }
        else
          %{ip: ip_str, country: nil, result: "no_geoip_match"}
        end
      end)

    json(conn, %{status: "done", ips_found: length(ips), results: results})
  end

  def test_dashboard(conn, _params) do
    alias Spectabas.{Sites, Analytics, Accounts}

    site = Spectabas.Repo.get!(Sites.Site, 1)
    user = Spectabas.Repo.one!(Accounts.User)

    today = Date.utc_today()
    from = Date.add(today, -7)

    date_range = %{
      from: DateTime.new!(from, ~T[00:00:00]),
      to: DateTime.new!(today, ~T[23:59:59])
    }

    results = %{
      overview: safe_test(fn -> Analytics.overview_stats(site, user, date_range) end),
      timeseries: safe_test(fn -> Analytics.timeseries(site, user, date_range, :week) end),
      timeseries_raw: case Analytics.timeseries(site, user, date_range, :week) do
        {:ok, rows} -> Enum.take(rows, 5)
        other -> inspect(other) |> String.slice(0, 300)
      end,
      top_pages: safe_test(fn -> Analytics.top_pages(site, user, date_range) end),
      top_sources: safe_test(fn -> Analytics.top_sources(site, user, date_range) end),
      top_regions: safe_test(fn -> Analytics.top_regions(site, user, date_range) end),
      top_devices: safe_test(fn -> Analytics.top_devices(site, user, date_range) end),
      entry_pages: safe_test(fn -> Analytics.entry_pages(site, user, date_range) end)
    }

    json(conn, results)
  end

  defp safe_test(fun) do
    case fun.() do
      {:ok, data} -> %{status: "ok", rows: length(List.wrap(data))}
      {:error, e} -> %{status: "error", reason: inspect(e) |> String.slice(0, 300)}
      other -> %{status: "unexpected", value: inspect(other) |> String.slice(0, 300)}
    end
  rescue
    e -> %{status: "crash", error: Exception.message(e) |> String.slice(0, 300)}
  end

  defp test_geoip do
    priv_dir = :code.priv_dir(:spectabas) |> to_string()
    city_path = Path.join([priv_dir, "geoip", "dbip-city-lite.mmdb"])
    asn_path = Path.join([priv_dir, "geoip", "dbip-asn-lite.mmdb"])

    city_lookup = Geolix.lookup({8, 8, 8, 8}, where: :city)

    country =
      case city_lookup do
        %{country: %{iso_code: code}} -> code
        _ -> "no_result"
      end

    %{
      priv_dir: priv_dir,
      city_file_exists: File.exists?(city_path),
      asn_file_exists: File.exists?(asn_path),
      city_file_size: if(File.exists?(city_path), do: File.stat!(city_path).size, else: 0),
      test_lookup_8888: country,
      test_lookup_174: test_full_lookup("174.252.144.194")
    }
  end

  defp test_full_lookup(ip_str) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(ip_str))
    city_result = Geolix.lookup(ip, where: :city)

    raw_keys = if is_map(city_result), do: Map.keys(city_result) |> Enum.map(&to_string/1), else: ["not_a_map"]
    raw_city = if is_map(city_result), do: inspect(city_result[:city]) |> String.slice(0, 200), else: "nil"
    raw_subs = if is_map(city_result), do: inspect(city_result[:subdivisions]) |> String.slice(0, 200), else: "nil"

    %{
      raw_keys: raw_keys,
      raw_city: raw_city,
      raw_subdivisions: raw_subs,
      country: case city_result do
        %{country: %{iso_code: c}} -> c
        _ -> "none"
      end,
      enricher_result: case Spectabas.IPEnricher.enrich(ip_str, :off) do
        %{ip_region_name: r, ip_city: c, ip_country: co} -> %{country: co, region: r, city: c}
        other -> inspect(other) |> String.slice(0, 200)
      end
    }
  end

  defp test_geo_sample do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query(
             "SELECT ip_country, ip_city, ip_address, count() AS c FROM events WHERE site_id = 1 GROUP BY ip_country, ip_city, ip_address ORDER BY c DESC LIMIT 5"
           ) do
        {:ok, rows} -> rows
        {:error, e} -> "error: #{String.slice(to_string(e), 0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_sites do
    Spectabas.Repo.all(Spectabas.Sites.Site)
    |> Enum.map(fn s -> %{id: s.id, domain: s.domain, public_key: s.public_key} end)
  end
end
