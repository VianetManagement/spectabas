defmodule Spectabas.Workers.GeoIPRefresh do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Spectabas.GeoIP.DownloadLog

  @impl Oban.Worker
  def perform(_job) do
    priv_dir = :code.priv_dir(:spectabas)
    geoip_dir = Path.join(priv_dir, "geoip")
    persistent_dir = System.get_env("PERSISTENT_DIR")
    target_dir = if persistent_dir, do: Path.join(persistent_dir, "geoip"), else: geoip_dir

    File.mkdir_p!(target_dir)

    # 1. DB-IP (free, monthly)
    refresh_dbip(target_dir)

    # 2. MaxMind GeoLite2 (free with license key)
    refresh_maxmind(target_dir)

    # 3. ipapi.is VPN databases (paid, $79/mo)
    refresh_ipapi_vpn(target_dir)

    # Clear IP cache so new lookups use fresh data
    if Process.whereis(Spectabas.IPEnricher.IPCache) do
      Spectabas.IPEnricher.IPCache.clear()
    end

    :ok
  end

  # --- DB-IP ---

  defp refresh_dbip(target_dir) do
    now = Date.utc_today()
    year = now.year
    month = now.month |> Integer.to_string() |> String.pad_leading(2, "0")

    for {name, url_suffix, geolix_id} <- [
          {"dbip-city-lite", "dbip-city-lite-#{year}-#{month}.mmdb.gz", :city},
          {"dbip-asn-lite", "dbip-asn-lite-#{year}-#{month}.mmdb.gz", :asn}
        ] do
      url = "https://download.db-ip.com/free/#{url_suffix}"
      dest = Path.join(target_dir, "#{name}.mmdb")

      timed_download(name, fn ->
        case download_and_gunzip(url) do
          {:ok, data} ->
            File.write!(dest, data)
            Geolix.load_database(%{id: geolix_id, adapter: Geolix.Adapter.MMDB2, source: dest})
            {:ok, byte_size(data)}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  # --- MaxMind ---

  defp refresh_maxmind(target_dir) do
    key = System.get_env("MAXMIND_LICENSE_KEY")

    if key && key != "" do
      url =
        "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=#{key}&suffix=tar.gz"

      dest = Path.join(target_dir, "GeoLite2-City.mmdb")

      timed_download("maxmind-geolite2-city", fn ->
        case download_and_extract_tar(url, ".mmdb") do
          {:ok, data} ->
            File.write!(dest, data)

            Geolix.load_database(%{
              id: :maxmind_city,
              adapter: Geolix.Adapter.MMDB2,
              source: dest
            })

            {:ok, byte_size(data)}

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  # --- ipapi.is VPN ---

  defp refresh_ipapi_vpn(target_dir) do
    api_key = System.get_env("IPAPI_API_KEY")

    if api_key && api_key != "" do
      url =
        "https://ipapi.is/app/getData?type=ipToVpn&format=mmdb&apiKey=#{api_key}"

      timed_download("ipapi-vpn-archive", fn ->
        case Req.get(url, receive_timeout: 300_000, raw: true) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

            loaded = 0

            loaded =
              Enum.reduce(files, loaded, fn {name_cl, data}, acc ->
                name = to_string(name_cl)

                case name do
                  "enumerated-vpn.mmdb" ->
                    dest = Path.join(target_dir, name)
                    File.write!(dest, data)

                    Geolix.load_database(%{
                      id: :vpn_enumerated,
                      adapter: Geolix.Adapter.MMDB2,
                      source: dest
                    })

                    log_sub_download("ipapi-vpn-enumerated", byte_size(data))
                    acc + 1

                  "interpolated-vpn.mmdb" ->
                    dest = Path.join(target_dir, name)
                    File.write!(dest, data)

                    Geolix.load_database(%{
                      id: :vpn_interpolated,
                      adapter: Geolix.Adapter.MMDB2,
                      source: dest
                    })

                    log_sub_download("ipapi-vpn-interpolated", byte_size(data))
                    acc + 1

                  _ ->
                    acc
                end
              end)

            {:ok, byte_size(body), "extracted #{loaded} MMDB files"}

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status} from ipapi.is"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end)
    end
  end

  # --- Helpers ---

  defp timed_download(name, fun) do
    start = System.monotonic_time(:millisecond)
    Logger.notice("[GeoIPRefresh] Downloading #{name}...")

    case fun.() do
      {:ok, size} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.notice("[GeoIPRefresh] #{name}: #{size} bytes in #{ms}ms")
        DownloadLog.log_download(name, "success", file_size: size, duration_ms: ms)

      {:ok, size, note} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.notice("[GeoIPRefresh] #{name}: #{size} bytes in #{ms}ms (#{note})")
        DownloadLog.log_download(name, "success", file_size: size, duration_ms: ms)

      {:error, reason} ->
        ms = System.monotonic_time(:millisecond) - start
        msg = if is_binary(reason), do: reason, else: inspect(reason)
        Logger.warning("[GeoIPRefresh] #{name} failed: #{msg}")
        DownloadLog.log_download(name, "error", error_message: msg, duration_ms: ms)
    end
  rescue
    e ->
      msg = Exception.message(e)
      Logger.error("[GeoIPRefresh] #{name} error: #{msg}")
      DownloadLog.log_download(name, "error", error_message: msg)
  end

  defp log_sub_download(name, size) do
    Logger.notice("[GeoIPRefresh] #{name}: #{size} bytes")
    DownloadLog.log_download(name, "success", file_size: size)
  end

  defp download_and_gunzip(url) do
    case Req.get(url, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} ->
        data = :zlib.gunzip(body)

        if byte_size(data) > 1_000_000 and String.contains?(data, <<0xAB, 0xCD, 0xEF>>) do
          {:ok, data}
        else
          {:error, "Invalid MMDB (#{byte_size(data)} bytes)"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp download_and_extract_tar(url, extension) do
    case Req.get(url, receive_timeout: 120_000, raw: true) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

        case Enum.find(files, fn {n, _} -> String.ends_with?(to_string(n), extension) end) do
          {_, data} -> {:ok, data}
          nil -> {:error, "No #{extension} file in archive"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
