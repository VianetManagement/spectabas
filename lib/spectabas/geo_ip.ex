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

    # ipapi.is VPN databases (optional, $79/mo subscription)
    # Loaded from persistent cache, priv/geoip, or downloaded on first boot if IPAPI_API_KEY is set
    vpn_loaded =
      for {filename, db_id} <- [
            {"enumerated-vpn.mmdb", :vpn_enumerated},
            {"interpolated-vpn.mmdb", :vpn_interpolated}
          ] do
        cond do
          File.exists?(Path.join(cache_dir, filename)) ->
            load_db(cache_dir, filename, db_id)
            true

          File.exists?(Path.join(geoip_dir, filename)) ->
            if persistent_dir,
              do: File.cp(Path.join(geoip_dir, filename), Path.join(cache_dir, filename))

            load_db(geoip_dir, filename, db_id)
            true

          true ->
            false
        end
      end

    # If VPN databases not found locally, download from ipapi.is on first boot
    if not Enum.all?(vpn_loaded) do
      api_key = System.get_env("IPAPI_API_KEY")

      if api_key && api_key != "" do
        Logger.info("[GeoIP] VPN databases not found, downloading from ipapi.is...")
        download_ipapi_vpn(api_key, cache_dir)
      else
        Logger.info("[GeoIP] VPN databases not found (set IPAPI_API_KEY to auto-download)")
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

  defp download_ipapi_vpn(api_key, target_dir) do
    url = "https://ipapi.is/app/getData?type=ipToVpn&format=mmdb&apiKey=#{api_key}"

    case Req.get(url, receive_timeout: 300_000, raw: true) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

        for {name_cl, data} <- files do
          name = to_string(name_cl)

          case name do
            "enumerated-vpn.mmdb" ->
              dest = Path.join(target_dir, name)
              File.write!(dest, data)
              load_db(target_dir, name, :vpn_enumerated)
              Logger.info("[GeoIP] Downloaded ipapi VPN enumerated: #{byte_size(data)} bytes")

            "interpolated-vpn.mmdb" ->
              dest = Path.join(target_dir, name)
              File.write!(dest, data)
              load_db(target_dir, name, :vpn_interpolated)
              Logger.info("[GeoIP] Downloaded ipapi VPN interpolated: #{byte_size(data)} bytes")

            _ ->
              :ok
          end
        end

      {:ok, %{status: status}} ->
        Logger.warning("[GeoIP] ipapi.is VPN download HTTP #{status}")

      {:error, reason} ->
        Logger.warning("[GeoIP] ipapi.is VPN download failed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[GeoIP] ipapi.is VPN download error: #{Exception.message(e)}")
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
