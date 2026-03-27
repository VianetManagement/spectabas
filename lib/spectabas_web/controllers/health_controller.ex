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
      sites: test_sites(),
      write_test: test_write()
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

  defp test_sites do
    Spectabas.Repo.all(Spectabas.Sites.Site)
    |> Enum.map(fn s -> %{id: s.id, domain: s.domain, public_key: s.public_key} end)
  end
end
