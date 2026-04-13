defmodule Spectabas.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        Spectabas.Visitors.Cache,
        SpectabasWeb.Telemetry,
        Spectabas.Repo,
        Spectabas.ObanRepo,
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

    # Notify Slack on deploy (async, non-blocking)
    Task.start(fn ->
      Spectabas.Notifications.Slack.notify(":rocket: *Spectabas deployed* — v5.22.1")
    end)

    # One-time backfill of daily_rollup if empty. Delayed so CH schema is ready.
    Task.start(fn ->
      Process.sleep(60_000)
      maybe_backfill_daily_rollup()
    end)

    result
  end

  defp maybe_backfill_daily_rollup do
    cfg = Application.get_env(:spectabas, Spectabas.ClickHouse, [])

    if cfg[:url] && cfg[:url] != "" && !String.contains?(cfg[:url], "placeholder") do
      case Spectabas.ClickHouse.query("SELECT count() AS c FROM daily_rollup") do
        {:ok, [%{"c" => c}]} ->
          count =
            case c do
              n when is_integer(n) -> n
              n when is_binary(n) -> String.to_integer(n)
              _ -> 0
            end

          if count == 0 do
            Logger.notice("[DailyRollup] Empty — enqueueing historical backfill")
            Oban.insert(Spectabas.Workers.DailyRollup.new(%{"backfill" => true}))
          end

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("[DailyRollup] Startup check skipped: #{inspect(e)}")
      :ok
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
