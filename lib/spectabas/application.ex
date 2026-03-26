defmodule Spectabas.Application do
  @moduledoc false

  use Application
  require Logger

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    enforce_secrets!()

    children = [
      SpectabasWeb.Telemetry,
      Spectabas.Repo,
      {DNSCluster, query: Application.get_env(:spectabas, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Spectabas.PubSub},
      {Finch, name: Spectabas.Finch},
      {Oban, Application.fetch_env!(:spectabas, Oban)},
      Spectabas.ClickHouse,
      Spectabas.Events.IngestBuffer,
      Spectabas.GeoIP,
      Spectabas.IPEnricher.ASNBlocklist,
      Spectabas.IPEnricher.IPCache,
      Spectabas.Sites.DomainCache,
      SpectabasWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Spectabas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SpectabasWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp enforce_secrets! do
    if @env == :prod do
      cfg = Application.get_env(:spectabas, Spectabas.ClickHouse, [])

      if Enum.any?([cfg[:password], cfg[:read_password]], fn p ->
           is_nil(p) or String.contains?(to_string(p), "CHANGE_ME")
         end) do
        raise "ClickHouse passwords not set. Set CLICKHOUSE_WRITER_PASSWORD and CLICKHOUSE_READER_PASSWORD."
      end
    end
  end
end
