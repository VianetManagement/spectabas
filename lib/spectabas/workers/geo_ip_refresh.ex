defmodule Spectabas.Workers.GeoIPRefresh do
  @moduledoc """
  Downloads fresh DB-IP mmdb files and replaces the existing ones.
  Runs monthly. Currently logs intent since actual downloads require
  external network access and the free DB-IP files.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    priv_dir = :code.priv_dir(:spectabas)
    geoip_dir = Path.join(priv_dir, "geoip")
    # Write to persistent storage if available (survives deploys)
    persistent_dir = System.get_env("PERSISTENT_DIR")
    target_dir = if persistent_dir, do: Path.join(persistent_dir, "geoip"), else: geoip_dir

    File.mkdir_p!(target_dir)

    now = Date.utc_today()
    year = now.year
    month = now.month |> Integer.to_string() |> String.pad_leading(2, "0")

    city_url =
      "https://download.db-ip.com/free/dbip-city-lite-#{year}-#{month}.mmdb.gz"

    asn_url =
      "https://download.db-ip.com/free/dbip-asn-lite-#{year}-#{month}.mmdb.gz"

    city_path = Path.join(target_dir, "dbip-city-lite.mmdb")
    asn_path = Path.join(target_dir, "dbip-asn-lite.mmdb")

    with :ok <- download_and_decompress(city_url, city_path),
         :ok <- download_and_decompress(asn_url, asn_path) do
      Logger.info("[GeoIPRefresh] Updated DB-IP databases for #{year}-#{month}")

      Geolix.load_database(%{id: :city, adapter: Geolix.Adapter.MMDB2, source: city_path})
      Geolix.load_database(%{id: :asn, adapter: Geolix.Adapter.MMDB2, source: asn_path})

      # Also refresh MaxMind GeoLite2 if license key is available
      maxmind_key = System.get_env("MAXMIND_LICENSE_KEY")

      if maxmind_key && maxmind_key != "" do
        maxmind_url =
          "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=#{maxmind_key}&suffix=tar.gz"

        maxmind_path = Path.join(target_dir, "GeoLite2-City.mmdb")

        case download_maxmind(maxmind_url, maxmind_path) do
          :ok ->
            Geolix.load_database(%{
              id: :maxmind_city,
              adapter: Geolix.Adapter.MMDB2,
              source: maxmind_path
            })

            Logger.info("[GeoIPRefresh] Updated MaxMind GeoLite2-City")

          {:error, reason} ->
            Logger.warning("[GeoIPRefresh] MaxMind update failed: #{inspect(reason)}")
        end
      end

      # Clear the IP cache so new lookups use fresh data
      if Process.whereis(Spectabas.IPEnricher.IPCache) do
        Spectabas.IPEnricher.IPCache.clear()
      end

      :ok
    else
      {:error, reason} ->
        Logger.error("[GeoIPRefresh] Failed to update GeoIP databases: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp download_and_decompress(url, dest_path) do
    Logger.info("[GeoIPRefresh] Downloading #{url}")

    case Req.get(url, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} ->
        decompressed = :zlib.gunzip(body)

        # Basic integrity check: MMDB files should be >1MB and contain the metadata marker
        if byte_size(decompressed) > 1_000_000 and
             String.contains?(decompressed, <<0xAB, 0xCD, 0xEF>>) do
          File.write!(dest_path, decompressed)
          Logger.info("[GeoIPRefresh] Wrote #{byte_size(decompressed)} bytes to #{dest_path}")
          :ok
        else
          {:error,
           "Downloaded file does not appear to be a valid MMDB (#{byte_size(decompressed)} bytes)"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} for #{url}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[GeoIPRefresh] Error downloading #{url}: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp download_maxmind(url, dest_path) do
    Logger.info("[GeoIPRefresh] Downloading MaxMind GeoLite2-City")

    case Req.get(url, receive_timeout: 120_000, raw: true) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # MaxMind comes as tar.gz; extract in memory
        {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

        case Enum.find(files, fn {name, _} -> String.ends_with?(to_string(name), ".mmdb") end) do
          {_, mmdb_data} ->
            File.write!(dest_path, mmdb_data)
            Logger.info("[GeoIPRefresh] MaxMind: #{byte_size(mmdb_data)} bytes to #{dest_path}")
            :ok

          nil ->
            {:error, "No .mmdb file found in MaxMind archive"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} from MaxMind"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[GeoIPRefresh] MaxMind download error: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end
end
