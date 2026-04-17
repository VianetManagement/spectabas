defmodule Spectabas.GeoIP do
  use GenServer
  require Logger

  @databases [
    %{id: :city, filename: "dbip-city-lite.mmdb", provider: :dbip},
    %{id: :asn, filename: "dbip-asn-lite.mmdb", provider: :dbip},
    %{id: :maxmind_city, filename: "GeoLite2-City.mmdb", provider: :maxmind},
    %{id: :vpn_enumerated, filename: "enumerated-vpn.mmdb", provider: :ipapi_vpn},
    %{id: :vpn_interpolated, filename: "interpolated-vpn.mmdb", provider: :ipapi_vpn}
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def databases, do: @databases

  def data_dir do
    persistent_dir = System.get_env("PERSISTENT_DIR")
    priv_dir = :code.priv_dir(:spectabas) |> to_string()

    dir =
      if persistent_dir,
        do: Path.join(persistent_dir, "geoip"),
        else: Path.join(priv_dir, "geoip")

    File.mkdir_p!(dir)
    dir
  end

  @impl true
  def init(_opts) do
    dir = data_dir()
    priv_dir = Path.join(:code.priv_dir(:spectabas) |> to_string(), "geoip")

    # Try loading each database from persistent storage or priv (Docker fallback)
    missing =
      Enum.filter(@databases, fn db ->
        path = Path.join(dir, db.filename)
        priv_path = Path.join(priv_dir, db.filename)

        cond do
          File.exists?(path) ->
            load_db(path, db.id)
            false

          File.exists?(priv_path) ->
            File.cp(priv_path, path)
            load_db(path, db.id)
            false

          true ->
            true
        end
      end)

    # Download missing databases by provider
    if missing != [] do
      missing_providers = missing |> Enum.map(& &1.provider) |> Enum.uniq()

      Logger.notice(
        "[GeoIP] Missing databases: #{Enum.map(missing, & &1.filename) |> Enum.join(", ")}"
      )

      for provider <- missing_providers do
        download_provider(provider, dir)
      end
    end

    {:ok, %{}}
  end

  def load_db(path, id) do
    if File.exists?(path) do
      Geolix.load_database(%{id: id, adapter: Geolix.Adapter.MMDB2, source: path})
      Logger.info("[GeoIP] Loaded #{id} (#{format_size(File.stat!(path).size)})")
    end
  end

  def download_provider(provider, dir \\ nil) do
    dir = dir || data_dir()

    case provider do
      :dbip -> download_dbip(dir)
      :maxmind -> download_maxmind(dir)
      :ipapi_vpn -> download_ipapi_vpn(dir)
    end
  end

  # --- DB-IP (free, monthly) ---

  defp download_dbip(dir) do
    now = Date.utc_today()
    year = now.year
    month = now.month |> Integer.to_string() |> String.pad_leading(2, "0")

    for {suffix, filename, id} <- [
          {"city-lite", "dbip-city-lite.mmdb", :city},
          {"asn-lite", "dbip-asn-lite.mmdb", :asn}
        ] do
      url = "https://download.db-ip.com/free/dbip-#{suffix}-#{year}-#{month}.mmdb.gz"
      dest = Path.join(dir, filename)
      log_name = String.replace(filename, ".mmdb", "")

      timed_download(log_name, fn ->
        case Req.get(url, receive_timeout: 120_000) do
          {:ok, %{status: 200, body: body}} ->
            data = :zlib.gunzip(body)
            File.write!(dest, data)
            load_db(dest, id)
            {:ok, byte_size(data)}

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end)
    end
  end

  # --- MaxMind (free with license key) ---

  defp download_maxmind(dir) do
    key = System.get_env("MAXMIND_LICENSE_KEY")

    if !key || key == "" do
      Logger.info("[GeoIP] MAXMIND_LICENSE_KEY not set, skipping MaxMind")
      return_skip()
    else
      url =
        "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-City&license_key=#{key}&suffix=tar.gz"

      dest = Path.join(dir, "GeoLite2-City.mmdb")

      timed_download("maxmind-geolite2-city", fn ->
        case Req.get(url, receive_timeout: 120_000, raw: true) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

            case Enum.find(files, fn {n, _} -> String.ends_with?(to_string(n), ".mmdb") end) do
              {_, data} ->
                File.write!(dest, data)
                load_db(dest, :maxmind_city)
                {:ok, byte_size(data)}

              nil ->
                {:error, "No .mmdb in MaxMind archive"}
            end

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end)
    end
  end

  # --- ipapi.is VPN (paid, $79/mo) ---

  defp download_ipapi_vpn(dir) do
    api_key = System.get_env("IPAPI_API_KEY")

    if !api_key || api_key == "" do
      Logger.info("[GeoIP] IPAPI_API_KEY not set, skipping VPN databases")
      return_skip()
    else
      url = "https://ipapi.is/app/getData?type=ipToVpn&format=mmdb&apiKey=#{api_key}"

      timed_download("ipapi-vpn-archive", fn ->
        case Req.get(url, receive_timeout: 300_000, raw: true) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            {:ok, files} = :erl_tar.extract({:binary, body}, [:compressed, :memory])

            targets = %{
              "enumerated-vpn.mmdb" => :vpn_enumerated,
              "interpolated-vpn.mmdb" => :vpn_interpolated
            }

            count =
              Enum.reduce(files, 0, fn {name_cl, data}, acc ->
                name = to_string(name_cl)

                case Map.get(targets, name) do
                  nil ->
                    acc

                  geolix_id ->
                    dest = Path.join(dir, name)
                    File.write!(dest, data)
                    load_db(dest, geolix_id)
                    log_sub_download(String.replace(name, ".mmdb", ""), byte_size(data))
                    acc + 1
                end
              end)

            {:ok, byte_size(body), "extracted #{count} MMDB files"}

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
    Logger.notice("[GeoIP] Downloading #{name}...")

    case fun.() do
      {:ok, size} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.notice("[GeoIP] #{name}: #{format_size(size)} in #{ms}ms")

        Spectabas.GeoIP.DownloadLog.log_download(name, "success",
          file_size: size,
          duration_ms: ms
        )

      {:ok, size, note} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.notice("[GeoIP] #{name}: #{format_size(size)} in #{ms}ms (#{note})")

        Spectabas.GeoIP.DownloadLog.log_download(name, "success",
          file_size: size,
          duration_ms: ms
        )

      {:error, reason} ->
        ms = System.monotonic_time(:millisecond) - start
        msg = if is_binary(reason), do: reason, else: inspect(reason)
        Logger.warning("[GeoIP] #{name} failed: #{msg}")

        Spectabas.GeoIP.DownloadLog.log_download(name, "error",
          error_message: msg,
          duration_ms: ms
        )
    end
  rescue
    e ->
      msg = Exception.message(e)
      Logger.error("[GeoIP] #{name} error: #{msg}")
      Spectabas.GeoIP.DownloadLog.log_download(name, "error", error_message: msg)
  end

  defp log_sub_download(name, size) do
    Logger.notice("[GeoIP] #{name}: #{format_size(size)}")
    Spectabas.GeoIP.DownloadLog.log_download(name, "success", file_size: size)
  end

  defp return_skip, do: :ok

  defp format_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp format_size(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_size(bytes), do: "#{bytes} B"
end
