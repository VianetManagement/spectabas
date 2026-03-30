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

    # Load DB-IP databases (from priv, baked into Docker image)
    load_db(geoip_dir, "dbip-city-lite.mmdb", :city)
    load_db(geoip_dir, "dbip-asn-lite.mmdb", :asn)

    # MaxMind: check persistent cache first, then priv, then download
    maxmind_priv = Path.join(geoip_dir, "GeoLite2-City.mmdb")
    maxmind_cache = Path.join(cache_dir, "GeoLite2-City.mmdb")

    maxmind_path =
      cond do
        File.exists?(maxmind_cache) ->
          Logger.info("[GeoIP] Loaded MaxMind from persistent cache")
          maxmind_cache

        File.exists?(maxmind_priv) ->
          # Copy to persistent cache for next deploy
          if persistent_dir, do: File.cp(maxmind_priv, maxmind_cache)
          maxmind_priv

        true ->
          case System.get_env("MAXMIND_LICENSE_KEY") do
            key when is_binary(key) and key != "" ->
              Logger.info("[GeoIP] Downloading MaxMind GeoLite2-City...")
              # Download to persistent cache if available, otherwise priv
              target = if persistent_dir, do: maxmind_cache, else: maxmind_priv
              download_maxmind(key, target)
              target

            _ ->
              Logger.info("[GeoIP] MAXMIND_LICENSE_KEY not set, skipping MaxMind")
              maxmind_priv
          end
      end

    load_db(Path.dirname(maxmind_path), Path.basename(maxmind_path), :maxmind_city)

    {:ok, %{}}
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
