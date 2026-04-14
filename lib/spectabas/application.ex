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
      Spectabas.Notifications.Slack.notify(":rocket: *Spectabas deployed* — v5.28.1")
    end)

    # One-time backfill of daily_rollup if empty. Delayed so CH schema is ready.
    Task.start(fn ->
      Process.sleep(60_000)
      maybe_backfill_daily_rollup()
    end)

    # One-time backfill of ip_is_datacenter / ip_is_vpn / ip_is_tor flags on
    # existing events. The ASN-list parser was broken until v5.27.1 so every
    # historical event has these flags = 0. We enqueue the backfill if we see
    # a non-empty blocklist AND zero flagged rows in the last 30 days.
    Task.start(fn ->
      Process.sleep(90_000)
      maybe_backfill_asn_flags()
    end)

    result
  end

  defp maybe_backfill_asn_flags do
    cfg = Application.get_env(:spectabas, Spectabas.ClickHouse, [])

    if cfg[:url] && cfg[:url] != "" && !String.contains?(cfg[:url], "placeholder") do
      {dc, vpn, tor} = Spectabas.IPEnricher.ASNBlocklist.sizes()

      if dc + vpn + tor == 0 do
        Logger.warning("[BackfillASNFlags] Blocklists are empty — skipping backfill")
      else
        sql = """
        SELECT
          countIf(ip_is_datacenter = 1) AS dc,
          countIf(ip_is_vpn = 1) AS vpn,
          countIf(ip_is_tor = 1) AS tor
        FROM events
        WHERE timestamp >= now() - INTERVAL 30 DAY
        """

        case Spectabas.ClickHouse.query(sql) do
          {:ok, [%{"dc" => dc_rows, "vpn" => vpn_rows, "tor" => tor_rows}]} ->
            flagged = to_int(dc_rows) + to_int(vpn_rows) + to_int(tor_rows)

            # The parser bug made blocklists effectively empty since inception.
            # A tiny handful of flagged rows (a few hundred) may exist from
            # brief windows when the parser worked. Force the backfill if
            # flagged rows are absurdly low compared to blocklist size — a
            # healthy populated site should have way more flagged rows than
            # total blocklist entries.
            bl_size = dc + vpn + tor

            if flagged < bl_size * 10 do
              Logger.notice(
                "[BackfillASNFlags] Lists loaded (dc=#{dc}, vpn=#{vpn}, tor=#{tor}), only #{flagged} flagged rows in last 30d — enqueueing backfill"
              )

              Oban.insert(Spectabas.Workers.BackfillASNFlags.new(%{}))
            else
              Logger.notice(
                "[BackfillASNFlags] #{flagged} flagged rows present (threshold #{bl_size * 10}) — skipping backfill"
              )
            end

          _ ->
            :ok
        end
      end
    end
  rescue
    e ->
      Logger.warning("[BackfillASNFlags] Startup check skipped: #{inspect(e)}")
      :ok
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)
  defp to_int(_), do: 0

  defp maybe_backfill_daily_rollup do
    cfg = Application.get_env(:spectabas, Spectabas.ClickHouse, [])

    if cfg[:url] && cfg[:url] != "" && !String.contains?(cfg[:url], "placeholder") do
      # Check all 5 rollup tables — if ANY is empty, backfill kicks in.
      # Backfill is idempotent (DELETE then INSERT per table), so running it
      # even when only one dimension rollup is empty is safe.
      tables =
        ~w(daily_rollup daily_page_rollup daily_source_rollup daily_geo_rollup daily_device_rollup)

      any_empty? =
        Enum.any?(tables, fn table ->
          case Spectabas.ClickHouse.query("SELECT count() AS c FROM #{table}") do
            {:ok, [%{"c" => c}]} ->
              count =
                case c do
                  n when is_integer(n) -> n
                  n when is_binary(n) -> String.to_integer(n)
                  _ -> 0
                end

              count == 0

            _ ->
              false
          end
        end)

      if any_empty? do
        Logger.notice("[DailyRollup] One or more rollup tables empty — enqueueing backfill")
        Oban.insert(Spectabas.Workers.DailyRollup.new(%{"backfill" => true}))
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
