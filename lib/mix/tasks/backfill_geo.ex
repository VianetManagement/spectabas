defmodule Mix.Tasks.BackfillGeo do
  @moduledoc """
  One-time backfill of geographic data for events with empty ip_country.
  Looks up each distinct ip_address via Geolix and issues ALTER TABLE UPDATE.

  Usage: mix backfill_geo
  """

  use Mix.Task
  require Logger

  @shortdoc "Backfill GeoIP data for existing ClickHouse events"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    unless Process.whereis(Spectabas.ClickHouse) do
      Mix.raise("ClickHouse is not running")
    end

    Logger.info("[BackfillGeo] Querying distinct IPs with empty geo data...")

    sql = """
    SELECT DISTINCT ip_address
    FROM events
    WHERE ip_country = '' AND ip_address != ''
    """

    case Spectabas.ClickHouse.query(sql) do
      {:ok, rows} ->
        ips = Enum.map(rows, & &1["ip_address"])
        Logger.info("[BackfillGeo] Found #{length(ips)} distinct IPs to enrich")

        enriched =
          ips
          |> Enum.map(fn ip -> {ip, lookup(ip)} end)
          |> Enum.reject(fn {_ip, result} -> result == nil end)

        Logger.info("[BackfillGeo] Successfully looked up #{length(enriched)} IPs")

        Enum.each(enriched, fn {ip, geo} ->
          update_sql = """
          ALTER TABLE events UPDATE
            ip_country = #{Spectabas.ClickHouse.param(geo.country)},
            ip_country_name = #{Spectabas.ClickHouse.param(geo.country_name)},
            ip_continent = #{Spectabas.ClickHouse.param(geo.continent)},
            ip_continent_name = #{Spectabas.ClickHouse.param(geo.continent_name)},
            ip_region_code = #{Spectabas.ClickHouse.param(geo.region_code)},
            ip_region_name = #{Spectabas.ClickHouse.param(geo.region_name)},
            ip_city = #{Spectabas.ClickHouse.param(geo.city)},
            ip_lat = #{geo.lat},
            ip_lon = #{geo.lon},
            ip_accuracy_radius = #{geo.accuracy_radius},
            ip_timezone = #{Spectabas.ClickHouse.param(geo.timezone)},
            ip_asn = #{geo.asn},
            ip_asn_org = #{Spectabas.ClickHouse.param(geo.asn_org)},
            ip_org = #{Spectabas.ClickHouse.param(geo.org)}
          WHERE ip_address = #{Spectabas.ClickHouse.param(ip)}
            AND ip_country = ''
          """

          case Spectabas.ClickHouse.execute(update_sql) do
            :ok ->
              Logger.info(
                "[BackfillGeo] Updated #{ip} → #{geo.country} / #{geo.region_name} / #{geo.city}"
              )

            {:error, e} ->
              Logger.error("[BackfillGeo] Failed to update #{ip}: #{inspect(e)}")
          end
        end)

        Logger.info("[BackfillGeo] Done!")

      {:error, e} ->
        Mix.raise("Failed to query ClickHouse: #{inspect(e)}")
    end
  end

  defp lookup(ip_string) do
    ip = parse_ip(ip_string)

    case Geolix.lookup(ip, where: :city) do
      %{country: %{iso_code: _}} = city ->
        asn_result = Geolix.lookup(ip, where: :asn)
        asn_number = get_in_safe(asn_result, [:autonomous_system_number]) || 0
        asn_org = get_in_safe(asn_result, [:autonomous_system_organization]) || ""

        %{
          country: get_in_safe(city, [:country, :iso_code]) || "",
          country_name: get_localized(get_in_safe(city, [:country, :names])),
          continent: get_in_safe(city, [:continent, :code]) || "",
          continent_name: get_localized(get_in_safe(city, [:continent, :names])),
          region_code: get_subdivision_iso(city),
          region_name: get_subdivision_name(city),
          city: get_localized(get_in_safe(city, [:city, :names])),
          lat: get_in_safe(city, [:location, :latitude]) || 0.0,
          lon: get_in_safe(city, [:location, :longitude]) || 0.0,
          accuracy_radius: get_in_safe(city, [:location, :accuracy_radius]) || 0,
          timezone: get_in_safe(city, [:location, :time_zone]) || "",
          asn: asn_number,
          asn_org: asn_org,
          org: if(asn_number > 0, do: "AS#{asn_number} #{asn_org}", else: "")
        }

      _ ->
        nil
    end
  end

  defp parse_ip(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      {:error, _} -> {0, 0, 0, 0}
    end
  end

  defp get_in_safe(nil, _), do: nil
  defp get_in_safe(map, []), do: map
  defp get_in_safe(map, [k | rest]) when is_map(map), do: get_in_safe(Map.get(map, k), rest)
  defp get_in_safe(_, _), do: nil

  defp get_localized(nil), do: ""
  defp get_localized(names) when is_map(names), do: Map.get(names, "en", "") || ""
  defp get_localized(_), do: ""

  defp get_subdivision_iso(result) do
    case get_in_safe(result, [:subdivisions]) do
      [first | _] -> Map.get(first, :iso_code, "") || ""
      _ -> ""
    end
  end

  defp get_subdivision_name(result) do
    case get_in_safe(result, [:subdivisions]) do
      [first | _] -> get_localized(Map.get(first, :names))
      _ -> ""
    end
  end
end
