defmodule SpectabasWeb.HealthController do
  use SpectabasWeb, :controller

  def show(conn, _params) do
    status = Spectabas.Health.status()
    status_code = if status == "ok", do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{status: status})
  end

  def diag(conn, _params) do
    results = %{
      service_health: Spectabas.Health.detailed(),
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
      geo_sample: test_geo_sample(),
      rum_debug: test_rum_debug()
    }

    results = Map.put(results, :visitor_breakdown, test_visitor_breakdown())
    json(conn, results)
  end

  defp test_visitor_breakdown do
    if Process.whereis(Spectabas.ClickHouse) do
      sql = """
      SELECT
        site_id,
        uniq(visitor_id) AS total_visitors,
        uniqIf(visitor_id, ip_is_bot = 0) AS human_visitors,
        uniqIf(visitor_id, ip_is_bot = 1) AS bot_visitors,
        count() AS total_events,
        countIf(ip_is_bot = 1) AS bot_events,
        countIf(ip_is_datacenter = 1) AS datacenter_events,
        countIf(event_type = 'pageview') AS pageviews,
        countIf(event_type = 'pageview' AND ip_is_bot = 0) AS human_pageviews
      FROM events
      WHERE toDate(timestamp) = today()
      GROUP BY site_id
      ORDER BY total_events DESC
      """

      case Spectabas.ClickHouse.query(sql) do
        {:ok, rows} -> rows
        {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_rum_debug do
    if Process.whereis(Spectabas.ClickHouse) do
      # Summary by event_name
      summary_sql = """
      SELECT
        event_name, site_id,
        count() AS total,
        countIf(JSONExtractString(properties, 'page_load') != '') AS has_page_load,
        countIf(JSONExtractString(properties, 'ttfb') != '') AS has_ttfb,
        countIf(JSONExtractString(properties, 'dom_complete') != '') AS has_dom_complete,
        countIf(JSONExtractString(properties, 'fcp') != '') AS has_fcp
      FROM events
      WHERE event_name IN ('_rum', '_cwv')
        AND timestamp >= now() - INTERVAL 7 DAY
      GROUP BY event_name, site_id
      ORDER BY site_id, event_name
      """

      # Actual query result for site 2 (beverlyonmain)
      query_sql = """
      SELECT
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'page_load')),
          toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0)) AS median_page_load,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'ttfb')),
          toFloat64OrZero(JSONExtractString(properties, 'ttfb')) > 0)) AS median_ttfb,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'dom_complete')),
          toFloat64OrZero(JSONExtractString(properties, 'dom_complete')) > 0)) AS median_dom,
        round(quantileIf(0.5)(toFloat64OrZero(JSONExtractString(properties, 'fcp')),
          toFloat64OrZero(JSONExtractString(properties, 'fcp')) > 0)) AS median_fcp,
        count() AS samples
      FROM events
      WHERE event_name = '_rum'
        AND timestamp >= now() - INTERVAL 7 DAY
      """

      # Check how many page_load values are "NaN" vs real numbers
      nan_sql = """
      SELECT
        site_id,
        count() AS total,
        countIf(JSONExtractString(properties, 'page_load') = 'NaN') AS page_load_nan,
        countIf(toFloat64OrZero(JSONExtractString(properties, 'page_load')) > 0) AS page_load_real,
        countIf(JSONExtractString(properties, 'dom_complete') = 'NaN') AS dom_complete_nan,
        countIf(toFloat64OrZero(JSONExtractString(properties, 'dom_complete')) > 0) AS dom_complete_real
      FROM events
      WHERE event_name = '_rum'
        AND timestamp >= now() - INTERVAL 7 DAY
      GROUP BY site_id
      """

      # Sample raw properties
      sample_sql = """
      SELECT
        site_id,
        properties,
        timestamp
      FROM events
      WHERE event_name = '_rum'
        AND timestamp >= now() - INTERVAL 1 DAY
      ORDER BY timestamp DESC
      LIMIT 5
      """

      %{
        summary:
          case Spectabas.ClickHouse.query(summary_sql) do
            {:ok, rows} -> rows
            {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
          end,
        query_result:
          case Spectabas.ClickHouse.query(query_sql) do
            {:ok, rows} -> rows
            {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
          end,
        nan_analysis:
          case Spectabas.ClickHouse.query(nan_sql) do
            {:ok, rows} -> rows
            {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
          end,
        sample_events:
          case Spectabas.ClickHouse.query(sample_sql) do
            {:ok, rows} -> rows
            {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
          end
      }
    else
      "not_started"
    end
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
        "SELECT DISTINCT ip_address FROM events WHERE ip_region_name = '' AND ip_address != ''"
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
          country_name = geo_name(city, [:country, :names])
          continent = get_in(city, [:continent, :code]) || ""
          continent_name = geo_name(city, [:continent, :names])

          region_code =
            case city do
              %{subdivisions: [%{iso_code: c} | _]} -> c || ""
              _ -> ""
            end

          region_name =
            case city do
              %{subdivisions: [%{names: names} | _]} ->
                Map.get(names, "en") || Map.get(names, :en) || ""

              _ ->
                ""
            end

          city_name = geo_name(city, [:city, :names])

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
            ip_lat = #{ClickHouse.param(lat)},
            ip_lon = #{ClickHouse.param(lon)},
            ip_timezone = #{ClickHouse.param(tz)},
            ip_asn = #{ClickHouse.param(asn_num)},
            ip_asn_org = #{ClickHouse.param(asn_org)},
            ip_org = #{ClickHouse.param(if(asn_num > 0, do: "AS#{asn_num} #{asn_org}", else: ""))}
          WHERE ip_address = #{ClickHouse.param(ip_str)}
            AND ip_region_name = ''
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
      timeseries_raw:
        case Analytics.timeseries(site, user, date_range, :week) do
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

  def test_audit(conn, _params) do
    Spectabas.Audit.log("test.health_check", %{source: "diag"})

    count =
      Spectabas.Repo.aggregate(Spectabas.Accounts.AuditLog, :count)

    import Ecto.Query

    recent =
      Spectabas.Repo.all(
        from(a in Spectabas.Accounts.AuditLog,
          order_by: [desc: a.occurred_at],
          limit: 10
        )
      )
      |> Enum.map(fn l ->
        %{
          event: l.event,
          occurred_at: to_string(l.occurred_at),
          metadata: l.metadata
        }
      end)

    json(conn, %{total: count, recent: recent})
  end

  def optimize_ad_spend(conn, _params) do
    db = Spectabas.ClickHouse.database()

    case Spectabas.ClickHouse.execute("OPTIMIZE TABLE #{db}.ad_spend FINAL") do
      :ok -> json(conn, %{status: "ok", message: "ad_spend table optimized"})
      {:error, reason} -> json(conn, %{status: "error", message: inspect(reason)})
    end
  end

  def intent_diag(conn, _params) do
    # Show intent distribution across all sites with sample URLs per intent
    sql = """
    SELECT
      visitor_intent AS intent,
      site_id,
      uniq(visitor_id) AS visitors,
      count() AS events,
      groupArray(10)(url_path) AS sample_paths,
      groupArray(10)(referrer_domain) AS sample_referrers
    FROM events
    WHERE timestamp >= now() - INTERVAL 7 DAY
      AND ip_is_bot = 0
      AND event_type = 'pageview'
      AND visitor_intent != ''
    GROUP BY visitor_intent, site_id
    ORDER BY visitors DESC
    """

    result =
      case Spectabas.ClickHouse.query(sql) do
        {:ok, rows} -> rows
        {:error, e} -> %{error: inspect(e)}
      end

    json(conn, %{intent_distribution: result})
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

  defp geo_name(map, keys) do
    names = get_in(map, keys)
    if is_map(names), do: Map.get(names, "en") || Map.get(names, :en) || "", else: ""
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

    raw_keys =
      if is_map(city_result),
        do: Map.keys(city_result) |> Enum.map(&to_string/1),
        else: ["not_a_map"]

    raw_city =
      if is_map(city_result), do: inspect(city_result[:city]) |> String.slice(0, 200), else: "nil"

    raw_subs =
      if is_map(city_result),
        do: inspect(city_result[:subdivisions]) |> String.slice(0, 200),
        else: "nil"

    %{
      raw_keys: raw_keys,
      raw_city: raw_city,
      raw_subdivisions: raw_subs,
      country:
        case city_result do
          %{country: %{iso_code: c}} -> c
          _ -> "none"
        end,
      enricher_result:
        case Spectabas.IPEnricher.enrich(ip_str, :off) do
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

  # Security model for /ecom-diag, /fix-ch-schema, /click-id-diag:
  # These diagnostic endpoints are accessed via curl/browser URL bar (not LiveView),
  # so session-based auth is impractical. They are protected by the UTILITY_TOKEN env var
  # which must be non-empty and at least 16 characters. The token is compared in constant time
  # via Erlang's ==/2 on matching strings. These endpoints are not linked from any UI.
  defp valid_token?(token) do
    env_token = System.get_env("UTILITY_TOKEN", "")
    token != "" and byte_size(env_token) >= 16 and token == env_token
  end

  def import_matomo_test(conn, %{"token" => token} = params) do
    if valid_token?(token) do
      do_import_matomo_test(conn, params)
    else
      conn |> put_status(403) |> json(%{error: "forbidden"})
    end
  end

  def import_matomo_test(conn, _params) do
    conn |> put_status(403) |> json(%{error: "forbidden"})
  end

  defp do_import_matomo_test(conn, %{"action" => "status"}) do
    count = Spectabas.Imports.Matomo.imported_day_count(4)
    json(conn, %{imported_days: count})
  end

  defp do_import_matomo_test(conn, %{"action" => "rollback"}) do
    result = Spectabas.Imports.Matomo.rollback(4)
    json(conn, %{result: inspect(result)})
  end

  defp do_import_matomo_test(conn, %{"action" => "set_dates"}) do
    site = Spectabas.Sites.get_site!(4)

    {:ok, _} =
      site
      |> Spectabas.Sites.Site.changeset(%{
        native_start_date: ~D[2026-03-30],
        import_end_date: ~D[2026-03-29]
      })
      |> Spectabas.Repo.update()

    json(conn, %{ok: true, native_start_date: "2026-03-30", import_end_date: "2026-03-29"})
  end

  defp do_import_matomo_test(conn, %{"action" => "import"}) do
    Task.start(fn ->
      Spectabas.Imports.Matomo.import_range(
        4,
        "https://a.roommates.com",
        2,
        "8ed134b2e37850878a2c035ab4c13cd1",
        ~D[2025-04-01],
        ~D[2026-03-29]
      )
    end)

    json(conn, %{
      status: "started",
      message: "Importing into rollup tables. Check progress with action=status"
    })
  end

  defp do_import_matomo_test(conn, _params) do
    json(conn, %{
      actions: ["import", "status", "rollback", "set_dates"],
      usage: "?token=...&action=import|status|rollback"
    })
  end

  def click_id_diag(conn, %{"token" => token}) do
    unless valid_token?(token) do
      conn |> put_status(403) |> json(%{error: "forbidden"})
    else
      q1 =
        case Spectabas.ClickHouse.query(
               "SELECT click_id_type, count() AS c, uniq(visitor_id) AS v FROM events WHERE click_id != '' AND site_id = 4 AND timestamp >= now() - INTERVAL 7 DAY GROUP BY click_id_type"
             ) do
          {:ok, data} -> data
          {:error, r} -> [%{"error" => inspect(r) |> String.slice(0, 200)}]
        end

      q2 =
        case Spectabas.ClickHouse.query(
               "SELECT count() AS c FROM events WHERE site_id = 4 AND toDate(timestamp) = today()"
             ) do
          {:ok, data} -> data
          {:error, r} -> [%{"error" => inspect(r) |> String.slice(0, 200)}]
        end

      q3 =
        case Spectabas.ClickHouse.query("""
             WITH ad_sessions AS (
               SELECT session_id, any(visitor_id) AS visitor_id, any(click_id_type) AS group_key,
                 countIf(event_type = 'pageview') AS pages, maxIf(duration_s, event_type = 'duration') AS duration,
                 any(visitor_intent) AS intent
               FROM events WHERE site_id = 4 AND ip_is_bot = 0 AND click_id != ''
                 AND timestamp >= now() - INTERVAL 30 DAY
               GROUP BY session_id HAVING countIf(event_type = 'pageview') > 0
             )
             SELECT group_key, count() AS sessions, uniqExact(visitor_id) AS visitors,
               round(avg(pages), 1) AS avg_pages
             FROM ad_sessions GROUP BY group_key
             """) do
          {:ok, data} -> data
          {:error, r} -> [%{"error" => inspect(r) |> String.slice(0, 200)}]
        end

      site = Spectabas.Sites.get_site!(4)
      user = Spectabas.Repo.get!(Spectabas.Accounts.User, 1)
      range = %{from: DateTime.add(DateTime.utc_now(), -30, :day), to: DateTime.utc_now()}

      q4 =
        case Spectabas.Analytics.time_to_convert_by_source(site, user, range) do
          {:ok, data} -> data
          {:error, r} -> [%{"error" => inspect(r) |> String.slice(0, 300)}]
        end

      q5 =
        case Spectabas.Analytics.ad_visitor_paths(site, user, range) do
          {:ok, data} -> data
          {:error, r} -> [%{"error" => inspect(r) |> String.slice(0, 300)}]
        end

      q6 =
        case Spectabas.Analytics.visitor_quality_by_source(site, user, range) do
          {:ok, data} -> data
          {:error, r} -> [%{"error" => inspect(r) |> String.slice(0, 300)}]
        end

      json(conn, %{
        by_type: q1,
        today: q2,
        quality_test: q3,
        time_to_convert: q4,
        visitor_paths: q5,
        visitor_quality: q6
      })
    end
  end

  def click_id_diag(conn, _params) do
    conn |> put_status(403) |> json(%{error: "forbidden"})
  end

  def send_setup_emails(conn, %{"token" => token}) do
    unless valid_token?(token) do
      conn |> put_status(403) |> json(%{error: "forbidden"})
    else
      results = %{
        proxy:
          case Spectabas.Workers.ProxySetupEmail.perform(%Oban.Job{args: %{}}) do
            :ok -> "sent"
            {:error, reason} -> "error: #{inspect(reason)}"
          end,
        ad_setup:
          case Spectabas.Workers.AdSetupEmail.perform(%Oban.Job{args: %{}}) do
            :ok -> "sent"
            {:error, reason} -> "error: #{inspect(reason)}"
          end
      }

      json(conn, %{status: "done", results: results})
    end
  end

  def send_setup_emails(conn, _params) do
    conn |> put_status(403) |> json(%{error: "forbidden"})
  end

  def fix_ch_schema(conn, %{"token" => token}) do
    unless valid_token?(token) do
      conn |> put_status(403) |> json(%{error: "forbidden"})
    else
      db = Application.get_env(:spectabas, Spectabas.ClickHouse)[:database] || "spectabas"

      results =
        [
          {"refund_amount",
           Spectabas.ClickHouse.execute_admin(
             "ALTER TABLE #{db}.ecommerce_events ADD COLUMN IF NOT EXISTS refund_amount Decimal(12, 2) DEFAULT 0"
           )},
          {"import_source",
           Spectabas.ClickHouse.execute_admin(
             "ALTER TABLE #{db}.ecommerce_events ADD COLUMN IF NOT EXISTS import_source LowCardinality(String) DEFAULT ''"
           )},
          {"ad_spend",
           Spectabas.ClickHouse.execute_admin("""
           CREATE TABLE IF NOT EXISTS #{db}.ad_spend (
             site_id UInt64,
             date Date,
             platform LowCardinality(String),
             account_id String DEFAULT '',
             campaign_id String DEFAULT '',
             campaign_name String DEFAULT '',
             spend Decimal(12, 2) DEFAULT 0,
             clicks UInt64 DEFAULT 0,
             impressions UInt64 DEFAULT 0,
             currency LowCardinality(String) DEFAULT 'USD',
             synced_at DateTime DEFAULT now()
           ) ENGINE = ReplacingMergeTree(synced_at)
           PARTITION BY toYYYYMM(date)
           ORDER BY (site_id, date, platform, campaign_id)
           SETTINGS index_granularity = 8192
           """)},
          {"search_console_drop",
           Spectabas.ClickHouse.execute_admin("DROP TABLE IF EXISTS #{db}.search_console")},
          {"search_console_recreate",
           Spectabas.ClickHouse.execute_admin("""
           CREATE TABLE IF NOT EXISTS #{db}.search_console (
             site_id UInt64,
             date Date,
             query String,
             page String,
             country LowCardinality(String) DEFAULT '',
             device LowCardinality(String) DEFAULT '',
             source LowCardinality(String) DEFAULT 'google',
             clicks UInt32 DEFAULT 0,
             impressions UInt32 DEFAULT 0,
             ctr Float32 DEFAULT 0,
             position Float32 DEFAULT 0,
             synced_at DateTime DEFAULT now()
           ) ENGINE = ReplacingMergeTree(synced_at)
           PARTITION BY toYYYYMM(date)
           ORDER BY (site_id, date, query, page, country, device, source)
           SETTINGS index_granularity = 8192
           """)},
          {"subscription_events",
           Spectabas.ClickHouse.execute_admin("""
           CREATE TABLE IF NOT EXISTS #{db}.subscription_events (
             site_id UInt64,
             subscription_id String,
             customer_email String,
             visitor_id String DEFAULT '',
             plan_name String DEFAULT '',
             plan_interval LowCardinality(String) DEFAULT 'month',
             mrr_amount Decimal(12, 2) DEFAULT 0,
             currency LowCardinality(String) DEFAULT 'USD',
             status LowCardinality(String) DEFAULT 'active',
             event_type LowCardinality(String) DEFAULT 'snapshot',
             started_at DateTime DEFAULT now(),
             canceled_at DateTime DEFAULT toDateTime(0),
             current_period_end DateTime DEFAULT now(),
             snapshot_date Date DEFAULT today(),
             timestamp DateTime DEFAULT now()
           ) ENGINE = ReplacingMergeTree(timestamp)
           PARTITION BY toYYYYMM(snapshot_date)
           ORDER BY (site_id, snapshot_date, subscription_id)
           SETTINGS index_granularity = 8192
           """)}
        ]
        |> Enum.map(fn {name, result} -> {name, inspect(result)} end)
        |> Map.new()

      json(conn, %{status: "done", results: results})
    end
  end

  def fix_ch_schema(conn, _params) do
    conn |> put_status(403) |> json(%{error: "forbidden"})
  end

  def ecom_diag(conn, %{"token" => token, "site_id" => site_id} = params) do
    unless valid_token?(token) do
      conn |> put_status(403) |> json(%{error: "forbidden"})
    else
      case params["action"] do
        "sync" ->
          ecom_diag_sync(conn, params)

        "check_dupes" ->
          site = Spectabas.Sites.get_site!(site_id)
          ecom_diag_check_dupes(conn, site_id, site.timezone || "America/New_York")

        "fix_dupes" ->
          ecom_diag_fix_dupes(conn, site_id)

        "mrr_diag" ->
          ecom_diag_mrr(conn, site_id)

        "bing_diag" ->
          ecom_diag_bing(conn, site_id)

        _ ->
          ecom_diag_today(conn, site_id)
      end
    end
  end

  defp ecom_diag_today(conn, site_id) do
    site_p = Spectabas.ClickHouse.param(site_id)

    # Today's raw events
    raw =
      case Spectabas.ClickHouse.query("""
           SELECT order_id, revenue, import_source, visitor_id,
             toTimezone(timestamp, 'America/New_York') AS ts_et
           FROM ecommerce_events
           WHERE site_id = #{site_p}
             AND toDate(toTimezone(timestamp, 'America/New_York')) = today()
           ORDER BY timestamp DESC
           LIMIT 100
           """) do
        {:ok, rows} -> rows
        {:error, e} -> [%{"error" => inspect(e)}]
      end

    # Today's totals by import_source
    totals =
      case Spectabas.ClickHouse.query("""
           SELECT
             import_source,
             count() AS cnt,
             sum(revenue) AS rev,
             sum(refund_amount) AS refunds
           FROM ecommerce_events
           WHERE site_id = #{site_p}
             AND toDate(toTimezone(timestamp, 'America/New_York')) = today()
           GROUP BY import_source
           """) do
        {:ok, rows} -> rows
        {:error, e} -> [%{"error" => inspect(e)}]
      end

    # Today's deduped total
    deduped =
      case Spectabas.ClickHouse.query("""
           SELECT
             count() AS cnt,
             sum(revenue) AS rev,
             sum(refund_amount) AS refunds
           FROM ecommerce_events
           WHERE site_id = #{site_p}
             AND toDate(toTimezone(timestamp, 'America/New_York')) = today()
           """) do
        {:ok, rows} -> rows
        {:error, e} -> [%{"error" => inspect(e)}]
      end

    json(conn, %{
      today_raw_events: raw,
      today_by_source: totals,
      today_deduped: deduped
    })
  end

  defp ecom_diag_sync(conn, %{"token" => _token, "site_id" => site_id} = params) do
    bg = params["bg"] == "1"
    site = Spectabas.Sites.get_site!(site_id)
    today = Date.utc_today()

    # Support &start=2024-01-01 for explicit start date, or &days=N
    {start_date, days} =
      case params["start"] do
        nil ->
          d = String.to_integer(params["days"] || "1")
          {Date.add(today, -d), d}

        start_str ->
          sd = Date.from_iso8601!(start_str)
          {sd, Date.diff(today, sd)}
      end

    integration =
      Spectabas.AdIntegrations.list_for_site(site.id)
      |> Enum.find(&(&1.platform == "stripe" and &1.status == "active"))

    if is_nil(integration) do
      # Try to auto-repair from saved credentials
      creds = Spectabas.AdIntegrations.Credentials.get_for_platform(site, "stripe")
      api_key = creds["api_key"]

      if api_key in [nil, ""] do
        json(conn, %{
          error: "No active Stripe integration and no saved API key for site #{site_id}"
        })
      else
        # Clean up any revoked records
        Spectabas.AdIntegrations.list_for_site(site.id)
        |> Enum.filter(&(&1.platform == "stripe"))
        |> Enum.each(&Spectabas.Repo.delete/1)

        case Spectabas.AdIntegrations.connect(site.id, "stripe", %{
               access_token: api_key,
               refresh_token: "",
               account_id: "",
               account_name: "Stripe"
             }) do
          {:ok, new_int} ->
            json(conn, %{
              status: "repaired",
              integration_id: new_int.id,
              message: "Re-created Stripe integration. Run action=sync again."
            })

          {:error, reason} ->
            json(conn, %{error: "Failed to create integration: #{inspect(reason)}"})
        end
      end
    else
      if bg do
        # Background mode — start from oldest date, work forward
        Task.start(fn ->
          require Logger

          Logger.info("[StripSync:backfill] Starting from #{start_date}, #{days} days")

          Enum.each(0..days, fn offset ->
            date = Date.add(start_date, offset)

            Spectabas.AdIntegrations.Platforms.StripePlatform.sync_charges(
              site,
              integration,
              date
            )

            if rem(offset, 30) == 0 do
              Logger.info("[StripSync:backfill] Progress: day #{offset}/#{days} (#{date})")
            end
          end)

          Logger.info("[StripSync:backfill] Complete — #{days + 1} days processed")
        end)

        json(conn, %{
          status: "started_in_background",
          start_date: Date.to_iso8601(start_date),
          days: days + 1,
          message:
            "Sync running from #{start_date} forward. Already-imported days (pi_*) are skipped. Check logs for progress."
        })
      else
        # Foreground mode — wait for results (may timeout for large ranges)
        results =
          Enum.map(0..days, fn offset ->
            date = Date.add(start_date, offset)

            sync_result =
              Spectabas.AdIntegrations.Platforms.StripePlatform.sync_charges(
                site,
                integration,
                date
              )

            {Date.to_iso8601(date), inspect(sync_result)}
          end)

        total =
          case Spectabas.ClickHouse.query("""
               SELECT count() AS cnt, sum(revenue) AS rev
               FROM ecommerce_events
               WHERE site_id = #{Spectabas.ClickHouse.param(site.id)}
                 AND (order_id LIKE 'ch_%' OR order_id LIKE 'pi_%')
               """) do
            {:ok, [row | _]} -> row
            _ -> %{}
          end

        json(conn, %{
          integration_id: integration.id,
          days_synced: days + 1,
          sync_results: Map.new(results),
          stripe_total_in_ch: total
        })
      end
    end
  end

  defp ecom_diag_check_dupes(conn, site_id, timezone) do
    site_p = Spectabas.ClickHouse.param(site_id)
    tz_p = Spectabas.ClickHouse.param(timezone)

    # Count duplicate order_ids
    dupes =
      case Spectabas.ClickHouse.query("""
           SELECT order_id, count() AS cnt, any(revenue) AS rev
           FROM ecommerce_events
           WHERE site_id = #{site_p} AND (order_id LIKE 'ch_%' OR order_id LIKE 'pi_%')
           GROUP BY order_id
           HAVING cnt > 1
           ORDER BY cnt DESC
           LIMIT 20
           """) do
        {:ok, rows} -> rows
        {:error, e} -> [%{"error" => inspect(e)}]
      end

    # Total impact of duplicates
    dupe_impact =
      case Spectabas.ClickHouse.query("""
           SELECT
             count() AS total_rows,
             uniqExact(order_id) AS unique_orders,
             count() - uniqExact(order_id) AS duplicate_rows,
             sum(revenue) AS total_rev_with_dupes,
             (SELECT sum(rev) FROM (
               SELECT order_id, any(revenue) AS rev
               FROM ecommerce_events
               WHERE site_id = #{site_p} AND (order_id LIKE 'ch_%' OR order_id LIKE 'pi_%')
               GROUP BY order_id
             )) AS total_rev_deduped
           FROM ecommerce_events
           WHERE site_id = #{site_p} AND (order_id LIKE 'ch_%' OR order_id LIKE 'pi_%')
           """) do
        {:ok, [row | _]} -> row
        {:error, e} -> %{"error" => inspect(e)}
      end

    # Last month in UTC vs site timezone
    last_month_utc =
      case Spectabas.ClickHouse.query("""
           SELECT
             uniqExact(order_id) AS unique_orders,
             sum(revenue) AS rev
           FROM ecommerce_events
           WHERE site_id = #{site_p}
             AND (order_id LIKE 'ch_%' OR order_id LIKE 'pi_%')
             AND toStartOfMonth(timestamp) = toStartOfMonth(today() - 1)
           """) do
        {:ok, [row | _]} -> row
        _ -> %{}
      end

    last_month_tz =
      case Spectabas.ClickHouse.query("""
           SELECT
             uniqExact(order_id) AS unique_orders,
             sum(revenue) AS rev
           FROM ecommerce_events
           WHERE site_id = #{site_p}
             AND (order_id LIKE 'ch_%' OR order_id LIKE 'pi_%')
             AND toStartOfMonth(toTimezone(timestamp, #{tz_p})) = toStartOfMonth(today() - 1)
           """) do
        {:ok, [row | _]} -> row
        _ -> %{}
      end

    # All months breakdown (site timezone)
    by_month =
      case Spectabas.ClickHouse.query("""
           SELECT
             toStartOfMonth(toTimezone(timestamp, #{tz_p})) AS month,
             uniqExact(order_id) AS orders,
             sum(revenue) AS rev
           FROM ecommerce_events
           WHERE site_id = #{site_p} AND (order_id LIKE 'ch_%' OR order_id LIKE 'pi_%')
           GROUP BY month ORDER BY month
           """) do
        {:ok, rows} -> rows
        _ -> []
      end

    json(conn, %{
      duplicate_samples: dupes,
      overall_impact: dupe_impact,
      last_month_utc: last_month_utc,
      last_month_tz: last_month_tz,
      by_month_tz: by_month
    })
  end

  defp ecom_diag_fix_dupes(conn, site_id) do
    site_p = Spectabas.ClickHouse.param(site_id)

    # Find duplicate order_ids and delete all but the earliest row for each
    dupes_sql = """
    SELECT order_id
    FROM ecommerce_events
    WHERE site_id = #{site_p}
    GROUP BY order_id
    HAVING count() > 1
    """

    case Spectabas.ClickHouse.query(dupes_sql) do
      {:ok, rows} when rows != [] ->
        dupe_ids = Enum.map(rows, & &1["order_id"])

        # For each duplicate, keep the row with the earliest timestamp, delete the rest
        results =
          Enum.map(dupe_ids, fn oid ->
            oid_p = Spectabas.ClickHouse.param(oid)

            del_sql = """
            ALTER TABLE ecommerce_events DELETE
            WHERE site_id = #{site_p}
              AND order_id = #{oid_p}
              AND timestamp > (
                SELECT min(timestamp) FROM ecommerce_events
                WHERE site_id = #{site_p} AND order_id = #{oid_p}
              )
            """

            {oid, inspect(Spectabas.ClickHouse.execute(del_sql))}
          end)

        json(conn, %{
          action: "fix_dupes",
          duplicates_found: length(dupe_ids),
          results: Map.new(results),
          message:
            "Deleted extra rows for #{length(dupe_ids)} duplicate orders. Check again in a minute."
        })

      _ ->
        json(conn, %{action: "fix_dupes", duplicates_found: 0, message: "No duplicates found."})
    end
  end

  defp ecom_diag_mrr(conn, site_id) do
    site_p = Spectabas.ClickHouse.param(site_id)

    # MRR by status from ClickHouse
    by_status =
      case Spectabas.ClickHouse.query("""
           SELECT status, count() AS cnt, sum(mrr_amount) AS total_mrr,
             countIf(mrr_amount = 0) AS zero_mrr_count
           FROM subscription_events FINAL
           WHERE site_id = #{site_p}
             AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
           GROUP BY status
           ORDER BY total_mrr DESC
           """) do
        {:ok, rows} -> rows
        {:error, e} -> [%{"error" => inspect(e)}]
      end

    # Top 20 active subscriptions by MRR
    top_subs =
      case Spectabas.ClickHouse.query("""
           SELECT subscription_id, customer_email, plan_name, plan_interval, mrr_amount, status, currency
           FROM subscription_events FINAL
           WHERE site_id = #{site_p}
             AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
             AND status = 'active'
           ORDER BY mrr_amount DESC
           LIMIT 20
           """) do
        {:ok, rows} -> rows
        {:error, e} -> [%{"error" => inspect(e)}]
      end

    # Snapshot dates available
    snapshots =
      case Spectabas.ClickHouse.query("""
           SELECT snapshot_date, count() AS cnt, sum(mrr_amount) AS total_mrr
           FROM subscription_events FINAL
           WHERE site_id = #{site_p}
           GROUP BY snapshot_date
           ORDER BY snapshot_date DESC
           LIMIT 10
           """) do
        {:ok, rows} -> rows
        {:error, e} -> [%{"error" => inspect(e)}]
      end

    # Call Stripe API directly to count cancel_at_period_end
    stripe_diag = stripe_cancel_at_period_end_diag(site_id)

    json(conn, %{
      action: "mrr_diag",
      mrr_by_status: by_status,
      top_subscriptions: top_subs,
      recent_snapshots: snapshots,
      stripe_cancel_at_period_end: stripe_diag
    })
  end

  defp stripe_cancel_at_period_end_diag(site_id) do
    import Ecto.Query

    case Spectabas.Repo.one(
           from(a in Spectabas.AdIntegrations.AdIntegration,
             where: a.site_id == ^site_id and a.platform == "stripe" and a.status == "active",
             limit: 1
           )
         ) do
      nil ->
        %{error: "No active Stripe integration"}

      integration ->
        api_key = Spectabas.AdIntegrations.decrypt_access_token(integration)

        # Fetch first page of active subs WITH item expansion to calculate MRR
        qs = URI.encode_query([
          {"status", "active"},
          {"limit", "100"},
          {"expand[]", "data.items.data.price"}
        ])

        case Req.get("https://api.stripe.com/v1/subscriptions?#{qs}",
               headers: [
                 {"authorization", "Bearer #{api_key}"},
                 {"stripe-version", "2024-12-18.acacia"}
               ]
             ) do
          {:ok, %{status: 200, body: %{"data" => subs, "has_more" => has_more}}} ->
            cancel_count = Enum.count(subs, & &1["cancel_at_period_end"])

            # Calculate MRR for these 100 subs using our logic
            our_mrr =
              Enum.reduce(subs, 0.0, fn sub, acc ->
                items = get_in(sub, ["items", "data"]) || []
                item_mrr = Enum.reduce(items, 0.0, fn item, iacc ->
                  price = item["price"] || %{}
                  unit = (price["unit_amount"] || 0) / 100.0
                  qty = item["quantity"] || 1
                  interval = get_in(price, ["recurring", "interval"]) || "month"
                  ic = get_in(price, ["recurring", "interval_count"]) || 1
                  amount = unit * qty
                  mrr = case {interval, ic} do
                    {"month", n} -> amount / n
                    {"year", n} -> amount / (12.0 * n)
                    {"week", n} -> amount * 52.0 / (12.0 * n)
                    {"day", 30} -> amount
                    {"day", 7} -> amount * 52.0 / 12.0
                    {"day", n} -> amount * 365.0 / (12.0 * n)
                    _ -> amount
                  end
                  iacc + mrr
                end)
                acc + item_mrr
              end)

            # Show raw Stripe data for first 5 subs to compare
            sample =
              subs
              |> Enum.take(5)
              |> Enum.map(fn s ->
                items = get_in(s, ["items", "data"]) || []
                first_price = get_in(items, [Access.at(0), "price"]) || %{}
                %{
                  id: s["id"],
                  status: s["status"],
                  cancel_at_period_end: s["cancel_at_period_end"],
                  unit_amount: first_price["unit_amount"],
                  interval: get_in(first_price, ["recurring", "interval"]),
                  interval_count: get_in(first_price, ["recurring", "interval_count"]),
                  quantity: get_in(items, [Access.at(0), "quantity"]),
                  item_count: length(items)
                }
              end)

            %{
              page_size: length(subs),
              has_more: has_more,
              total_active_on_page: length(subs),
              cancel_at_period_end_count: cancel_count,
              our_mrr_for_page: Float.round(our_mrr, 2),
              avg_mrr_per_sub: Float.round(our_mrr / max(length(subs), 1), 2),
              sample_subs: sample
            }

          {:ok, %{status: s, body: b}} ->
            %{error: "Stripe API HTTP #{s}: #{inspect(b) |> String.slice(0, 200)}"}

          {:error, e} ->
            %{error: inspect(e) |> String.slice(0, 200)}
        end
    end
  end

  defp ecom_diag_bing(conn, site_id) do
    import Ecto.Query

    case Spectabas.Repo.one(
           from(a in Spectabas.AdIntegrations.AdIntegration,
             where: a.site_id == ^site_id and a.platform == "bing_webmaster" and a.status == "active",
             limit: 1
           )
         ) do
      nil ->
        json(conn, %{error: "No active Bing Webmaster integration"})

      integration ->
        api_key = Spectabas.AdIntegrations.decrypt_access_token(integration)
        site_url = (integration.extra || %{})["site_url"] || ""

        # Try multiple URL formats and endpoints
        variants = [
          {"GetQueryStats (bare)", "https://ssl.bing.com/webmaster/api.svc/json/GetQueryStats?apikey=#{api_key}&siteUrl=#{URI.encode(site_url, &URI.char_unreserved?/1)}"},
          {"GetQueryStats (https://)", "https://ssl.bing.com/webmaster/api.svc/json/GetQueryStats?apikey=#{api_key}&siteUrl=#{URI.encode("https://#{site_url}/", &URI.char_unreserved?/1)}"},
          {"GetQueryStats (http://)", "https://ssl.bing.com/webmaster/api.svc/json/GetQueryStats?apikey=#{api_key}&siteUrl=#{URI.encode("http://#{site_url}/", &URI.char_unreserved?/1)}"},
          {"GetQueryPageStats (bare)", "https://ssl.bing.com/webmaster/api.svc/json/GetQueryPageStats?apikey=#{api_key}&siteUrl=#{URI.encode(site_url, &URI.char_unreserved?/1)}"},
          {"GetQueryPageStats (bare+query)", "https://ssl.bing.com/webmaster/api.svc/json/GetQueryPageStats?apikey=#{api_key}&siteUrl=#{URI.encode(site_url, &URI.char_unreserved?/1)}&query=%27%27"}
        ]

        results =
          Enum.map(variants, fn {label, url} ->
            case Req.get(url, receive_timeout: 15_000) do
              {:ok, %{status: status, body: body}} ->
                row_count =
                  case body do
                    %{"d" => data} when is_list(data) -> length(data)
                    _ -> 0
                  end

                sample =
                  case body do
                    %{"d" => [first | _]} ->
                      %{keys: Map.keys(first), date: first["Date"], query: first["Query"]}

                    %{"d" => []} ->
                      %{empty_list: true}

                    _ ->
                      %{body_keys: if(is_map(body), do: Map.keys(body), else: "not_map"),
                        snippet: inspect(body) |> String.slice(0, 200)}
                  end

                %{label: label, status: status, rows: row_count, sample: sample}

              {:error, reason} ->
                %{label: label, error: inspect(reason) |> String.slice(0, 100)}
            end
          end)

        json(conn, %{
          action: "bing_diag",
          configured_site_url: site_url,
          results: results
        })
    end
  end

  defp test_sites do
    Spectabas.Repo.all(Spectabas.Sites.Site)
    |> Enum.map(fn s -> %{id: s.id, domain: s.domain, public_key: s.public_key} end)
  end
end
