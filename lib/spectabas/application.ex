defmodule Spectabas.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Spectabas.Visitors.Cache.init()

    children =
      [
        SpectabasWeb.Telemetry,
        Spectabas.Repo,
        {DNSCluster, query: Application.get_env(:spectabas, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Spectabas.PubSub},
        {Finch, name: Spectabas.Finch},
        {Finch,
         name: Spectabas.ClickHouseFinch,
         pools: %{
           :default => [size: 25, count: 4]
         }},
        {Oban, Application.fetch_env!(:spectabas, Oban)},
        Spectabas.GeoIP,
        Spectabas.IPEnricher.ASNBlocklist,
        Spectabas.IPEnricher.IPCache,
        Spectabas.Sessions.SessionCache,
        Spectabas.Sites.DomainCache,
        Spectabas.Sites.DNSVerifier
      ] ++
        clickhouse_children() ++
        [SpectabasWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Spectabas.Supervisor]
    result = Supervisor.start_link(children, opts)

    # One-shot email tasks (safe to call multiple times — unique key prevents duplicates)
    schedule_one_shot_emails()

    result
  end

  defp schedule_one_shot_emails do
    try do
      Oban.insert(
        Spectabas.Workers.AdSetupEmail.new(%{}, unique: [period: :infinity, keys: []])
      )
    rescue
      _ -> :ok
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    SpectabasWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp clickhouse_children do
    cfg = Application.get_env(:spectabas, Spectabas.ClickHouse, [])

    if cfg[:url] && cfg[:url] != "" && !String.contains?(cfg[:url], "placeholder") do
      [
        Spectabas.ClickHouse,
        {Task.Supervisor, name: Spectabas.IngestFlushSupervisor},
        Spectabas.Events.IngestBuffer
      ]
    else
      Logger.warning("ClickHouse not configured — analytics features disabled")
      []
    end
  end
end
