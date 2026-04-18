defmodule Spectabas.Workers.BackfillVpn do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Spectabas.{ClickHouse, GeoIP.DownloadLog}

  @batch_size 50000

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(600)

  @impl Oban.Worker
  def perform(_job) do
    start = System.monotonic_time(:millisecond)
    Logger.notice("[BackfillVpn] Starting VPN provider backfill...")

    {total_tagged, total_checked} = process_all_batches(0, 0)

    ms = System.monotonic_time(:millisecond) - start

    Logger.notice(
      "[BackfillVpn] Complete! #{total_checked} IPs checked, #{total_tagged} tagged, #{ms}ms"
    )

    DownloadLog.log_download("vpn-backfill", "success",
      file_size: total_tagged,
      duration_ms: ms,
      error_message: "#{total_checked} IPs checked, #{total_tagged} tagged"
    )

    :ok
  end

  defp process_all_batches(total_tagged, total_checked) do
    sql = """
    SELECT DISTINCT ip_address
    FROM events
    WHERE ip_address != '' AND ip_vpn_provider = ''
    LIMIT #{@batch_size}
    """

    case ClickHouse.query(sql, receive_timeout: 120_000) do
      {:ok, []} ->
        {total_tagged, total_checked}

      {:ok, rows} ->
        batch_size = length(rows)

        Logger.notice("[BackfillVpn] Batch: #{batch_size} IPs (cumulative: #{total_checked})")

        # Look up all IPs in Geolix (fast, in-memory) and group by result
        {vpn_groups, non_vpn_ips} =
          Enum.reduce(rows, {%{}, []}, fn row, {groups, non_vpn} ->
            ip = row["ip_address"]

            case Spectabas.IPEnricher.vpn_provider_for_ip(ip) do
              "" ->
                {groups, [ip | non_vpn]}

              provider ->
                {Map.update(groups, provider, [ip], &[ip | &1]), non_vpn}
            end
          end)

        # Batch update VPN IPs — one mutation per provider
        tagged =
          Enum.reduce(vpn_groups, 0, fn {provider, ips}, acc ->
            count = length(ips)
            Logger.notice("[BackfillVpn] Tagging #{count} IPs as #{provider}")
            batch_update_vpn(ips, provider)
            acc + count
          end)

        # Batch mark non-VPN IPs as checked (single space sentinel)
        if non_vpn_ips != [] do
          Logger.notice("[BackfillVpn] Marking #{length(non_vpn_ips)} non-VPN IPs as checked")
          batch_mark_checked(non_vpn_ips)
        end

        new_tagged = total_tagged + tagged
        new_checked = total_checked + batch_size

        if batch_size < @batch_size do
          {new_tagged, new_checked}
        else
          process_all_batches(new_tagged, new_checked)
        end

      {:error, e} ->
        Logger.error("[BackfillVpn] Query failed: #{inspect(e)}")
        DownloadLog.log_download("vpn-backfill", "error", error_message: inspect(e))
        {total_tagged, total_checked}
    end
  end

  defp batch_update_vpn(ips, provider) do
    ips
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      in_clause = chunk |> Enum.map(&ClickHouse.param/1) |> Enum.join(", ")

      sql = """
      ALTER TABLE events UPDATE
        ip_vpn_provider = #{ClickHouse.param(provider)},
        ip_is_vpn = 1,
        ip_is_datacenter = 0
      WHERE ip_address IN (#{in_clause})
      SETTINGS mutations_sync = 0
      """

      case ClickHouse.execute(sql) do
        :ok -> :ok
        {:error, e} -> Logger.warning("[BackfillVpn] Batch update failed: #{inspect(e)}")
      end
    end)
  end

  # Single mutation for all non-VPN IPs
  defp batch_mark_checked(ips) do
    # Process in chunks of 500 to stay under ClickHouse HTTP field length limit
    ips
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      in_clause = chunk |> Enum.map(&ClickHouse.param/1) |> Enum.join(", ")

      sql = """
      ALTER TABLE events UPDATE
        ip_vpn_provider = ' '
      WHERE ip_address IN (#{in_clause}) AND ip_vpn_provider = ''
      SETTINGS mutations_sync = 0
      """

      case ClickHouse.execute(sql) do
        :ok -> :ok
        {:error, e} -> Logger.warning("[BackfillVpn] Batch mark failed: #{inspect(e)}")
      end
    end)
  end
end
