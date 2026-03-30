defmodule Spectabas.GeoIP do
  @moduledoc """
  Manages GeoIP database loading via Geolix.
  Loads DB-IP (primary geo/ASN) and MaxMind GeoLite2 (timezone).
  Downloads MaxMind at runtime if MAXMIND_LICENSE_KEY is set.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    priv_dir = :code.priv_dir(:spectabas) |> to_string()
    geoip_dir = Path.join(priv_dir, "geoip")
    # Use persistent disk if available (survives deploys), fall back to priv
    persistent_dir = System.get_env("PERSISTENT_DIR")
    cache_dir = if persistent_dir, do: Path.join(persistent_dir, "geoip"), else: geoip_dir
    File.mkdir_p!(cache_dir)

    # Load DB-IP databases: prefer persistent cache, fall back to priv (Docker image)
    load_from_cache_or_priv(cache_dir, geoip_dir, "dbip-city-lite.mmdb", :city, persistent_dir)
    load_from_cache_or_priv(cache_dir, geoip_dir, "dbip-asn-lite.mmdb", :asn, persistent_dir)

    # MaxMind: check persistent cache, then priv, then download
    maxmind_file = "GeoLite2-City.mmdb"
    maxmind_priv = Path.join(geoip_dir, maxmind_file)
    maxmind_cache = Path.join(cache_dir, maxmind_file)

    cond do
      File.exists?(maxmind_cache) ->
        Logger.info("[GeoIP] Loaded MaxMind from persistent cache")
        load_db(cache_dir, maxmind_file, :maxmind_city)

      File.exists?(maxmind_priv) ->
        if persistent_dir, do: File.cp(maxmind_priv, maxmind_cache)
        load_db(geoip_dir, maxmind_file, :maxmind_city)

      true ->
        case System.get_env("MAXMIND_LICENSE_KEY") do
          key when is_binary(key) and key != "" ->
            Logger.info("[GeoIP] Downloading MaxMind GeoLite2-City...")
            target = if persistent_dir, do: maxmind_cache, else: maxmind_priv
            download_maxmind(key, target)
            load_db(Path.dirname(target), maxmind_file, :maxmind_city)

          _ ->
            Logger.info("[GeoIP] MAXMIND_LICENSE_KEY not set, skipping MaxMind")
        end
    end

    {:ok, %{}}
  end

  # Load from persistent cache if available, otherwise from priv (Docker image)
  defp load_from_cache_or_priv(cache_dir, priv_dir, filename, id, persistent_dir) do
    cache_path = Path.join(cache_dir, filename)
    priv_path = Path.join(priv_dir, filename)

    cond do
      File.exists?(cache_path) ->
        load_db(cache_dir, filename, id)

      File.exists?(priv_path) ->
        # Copy to persistent cache for next deploy
        if persistent_dir, do: File.cp(priv_path, cache_path)
        load_db(priv_dir, filename, id)

      true ->
        Logger.info("[GeoIP] #{filename} not found in cache or priv")
    end
  end

  defp load_db(dir, filename, id) do
    path = Path.join(dir, filename)

    if File.exists?(path) do
      Geolix.load_database(%{id: id, adapter: Geolix.Adapter.MMDB2, source: path})
      Logger.info("[GeoIP] Loaded #{id} from #{path}")
    else
      Logger.info("[GeoIP] Not found (optional): #{path}")
    end
  end

  defp download_maxmind(key, dest_path) do
    url =
      "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=#{key}&suffix=tar.gz"

    case Req.get(url, receive_timeout: 120_000, raw: true) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

        case Enum.find(files, fn {n, _} -> String.ends_with?(to_string(n), ".mmdb") end) do
          {_, data} ->
            File.write!(dest_path, data)
            Logger.info("[GeoIP] MaxMind downloaded: #{byte_size(data)} bytes")

          nil ->
            Logger.warning("[GeoIP] No .mmdb in MaxMind archive")
        end

      {:ok, %{status: s}} ->
        Logger.warning("[GeoIP] MaxMind download HTTP #{s}")

      {:error, e} ->
        Logger.warning("[GeoIP] MaxMind download failed: #{inspect(e)}")
    end
  rescue
    e -> Logger.warning("[GeoIP] MaxMind download error: #{Exception.message(e)}")
  end
end
