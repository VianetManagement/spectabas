defmodule Spectabas.Workers.BackfillGeo do
  @moduledoc """
  One-time Oban job to backfill GeoIP data for events with empty ip_country.
  Enqueue manually: Oban.insert(Spectabas.Workers.BackfillGeo.new(%{}))
  Or trigger via /health/backfill-geo endpoint.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Logger.info("[BackfillGeo] Starting geo backfill...")

    sql = """
    SELECT DISTINCT ip_address
    FROM events
    WHERE ip_country = '' AND ip_address != ''
    """

    case Spectabas.ClickHouse.query(sql) do
      {:ok, rows} ->
        ips = Enum.map(rows, & &1["ip_address"])
        Logger.info("[BackfillGeo] Found #{length(ips)} distinct IPs to enrich")

        {ok, failed} =
          Enum.reduce(ips, {0, 0}, fn ip, {ok, failed} ->
            case enrich_and_update(ip) do
              :ok -> {ok + 1, failed}
              :skip -> {ok, failed}
              :error -> {ok, failed + 1}
            end
          end)

        Logger.info("[BackfillGeo] Done! Updated #{ok} IPs, #{failed} failures")
        :ok

      {:error, e} ->
        Logger.error("[BackfillGeo] Failed to query ClickHouse: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end

  defp enrich_and_update(ip_string) do
    case lookup(ip_string) do
      nil ->
        :skip

      geo ->
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
        WHERE ip_address = #{Spectabas.ClickHouse.param(ip_string)}
          AND ip_country = ''
        """

        case Spectabas.ClickHouse.execute(update_sql) do
          :ok ->
            Logger.info("[BackfillGeo] #{ip_string} → #{geo.country}/#{geo.region_name}/#{geo.city}")
            :ok

          {:error, e} ->
            Logger.error("[BackfillGeo] Failed #{ip_string}: #{inspect(e)}")
            :error
        end
    end
  end

  defp lookup(ip_string) do
    ip = parse_ip(ip_string)

    case Geolix.lookup(ip, where: :city) do
      %{country: %{iso_code: _}} = city ->
        asn_result = Geolix.lookup(ip, where: :asn)
        asn_number = safe_get(asn_result, :autonomous_system_number) || 0
        asn_org = safe_get(asn_result, :autonomous_system_organization) || ""

        %{
          country: safe_nested(city, [:country, :iso_code]) || "",
          country_name: localized(safe_nested(city, [:country, :names])),
          continent: safe_nested(city, [:continent, :code]) || "",
          continent_name: localized(safe_nested(city, [:continent, :names])),
          region_code: subdivision_iso(city),
          region_name: subdivision_name(city),
          city: localized(safe_nested(city, [:city, :names])),
          lat: safe_nested(city, [:location, :latitude]) || 0.0,
          lon: safe_nested(city, [:location, :longitude]) || 0.0,
          accuracy_radius: safe_nested(city, [:location, :accuracy_radius]) || 0,
          timezone: safe_nested(city, [:location, :time_zone]) || "",
          asn: asn_number,
          asn_org: asn_org,
          org: if(asn_number > 0, do: "AS#{asn_number} #{asn_org}", else: "")
        }

      _ ->
        nil
    end
  end

  defp parse_ip(s) do
    case :inet.parse_address(String.to_charlist(s)) do
      {:ok, ip} -> ip
      _ -> {0, 0, 0, 0}
    end
  end

  defp safe_get(nil, _), do: nil
  defp safe_get(map, key) when is_map(map), do: Map.get(map, key)
  defp safe_get(_, _), do: nil

  defp safe_nested(nil, _), do: nil
  defp safe_nested(map, []), do: map
  defp safe_nested(map, [k | rest]) when is_map(map), do: safe_nested(Map.get(map, k), rest)
  defp safe_nested(_, _), do: nil

  defp localized(nil), do: ""
  defp localized(names) when is_map(names), do: Map.get(names, "en", "") || ""
  defp localized(_), do: ""

  defp subdivision_iso(result) do
    case safe_nested(result, [:subdivisions]) do
      [first | _] -> Map.get(first, :iso_code, "") || ""
      _ -> ""
    end
  end

  defp subdivision_name(result) do
    case safe_nested(result, [:subdivisions]) do
      [first | _] -> localized(Map.get(first, :names))
      _ -> ""
    end
  end
end
