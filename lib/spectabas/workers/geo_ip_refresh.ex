defmodule Spectabas.Workers.GeoIPRefresh do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(300)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider" => provider}}) do
    Spectabas.GeoIP.download_provider(String.to_existing_atom(provider))

    if Process.whereis(Spectabas.IPEnricher.IPCache) do
      Spectabas.IPEnricher.IPCache.clear()
    end

    :ok
  end

  def perform(_job) do
    Logger.notice("[GeoIPRefresh] Refreshing all GeoIP databases")

    for provider <- [:dbip, :maxmind, :ipapi_vpn] do
      Spectabas.GeoIP.download_provider(provider)
    end

    # Upload all MMDB files to R2 for stateless instance boot
    sync_to_r2()

    if Process.whereis(Spectabas.IPEnricher.IPCache) do
      Spectabas.IPEnricher.IPCache.clear()
    end

    :ok
  end

  defp sync_to_r2 do
    if Spectabas.R2.configured?() do
      dir = Spectabas.GeoIP.data_dir()

      dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".mmdb"))
      |> Enum.each(fn filename ->
        path = Path.join(dir, filename)
        body = File.read!(path)
        Spectabas.R2.upload("geoip/#{filename}", body)
      end)

      Logger.notice("[GeoIPRefresh] Synced MMDB files to R2")
    end
  end
end
