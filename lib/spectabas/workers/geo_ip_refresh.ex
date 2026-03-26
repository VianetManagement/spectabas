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

    File.mkdir_p!(geoip_dir)

    now = Date.utc_today()
    year = now.year
    month = now.month |> Integer.to_string() |> String.pad_leading(2, "0")

    city_url =
      "https://download.db-ip.com/free/dbip-city-lite-#{year}-#{month}.mmdb.gz"

    asn_url =
      "https://download.db-ip.com/free/dbip-asn-lite-#{year}-#{month}.mmdb.gz"

    city_path = Path.join(geoip_dir, "dbip-city-lite.mmdb")
    asn_path = Path.join(geoip_dir, "dbip-asn-lite.mmdb")

    with :ok <- download_and_decompress(city_url, city_path),
         :ok <- download_and_decompress(asn_url, asn_path) do
      Logger.info("[GeoIPRefresh] Successfully updated GeoIP databases for #{year}-#{month}")

      # Clear the IP cache so new lookups use fresh data
      if Process.whereis(Spectabas.IPEnricher.IPCache) do
        send(Spectabas.IPEnricher.IPCache, :clear)
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
        File.write!(dest_path, decompressed)
        Logger.info("[GeoIPRefresh] Wrote #{byte_size(decompressed)} bytes to #{dest_path}")
        :ok

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
end
