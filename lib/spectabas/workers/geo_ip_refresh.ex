defmodule Spectabas.Workers.GeoIPRefresh do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

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

    if Process.whereis(Spectabas.IPEnricher.IPCache) do
      Spectabas.IPEnricher.IPCache.clear()
    end

    :ok
  end
end
