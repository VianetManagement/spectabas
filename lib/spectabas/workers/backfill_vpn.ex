defmodule Spectabas.Workers.BackfillVpn do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Spectabas.GeoIP.DownloadLog

  @batch_size 50000

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

    case Spectabas.ClickHouse.query(sql, receive_timeout: 120_000) do
      {:ok, []} ->
        {total_tagged, total_checked}

      {:ok, rows} ->
        batch_size = length(rows)

        Logger.notice(
          "[BackfillVpn] Batch: #{batch_size} IPs (cumulative: #{total_checked} checked, #{total_tagged} tagged)"
        )

        {tagged, _skipped} =
          Enum.reduce(rows, {0, 0}, fn row, {tagged, skipped} ->
            ip = row["ip_address"]

            case Spectabas.IPEnricher.vpn_provider_for_ip(ip) do
              "" ->
                mark_checked(ip)
                {tagged, skipped + 1}

              provider ->
                update_vpn(ip, provider)
                {tagged + 1, skipped}
            end
          end)

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

  defp update_vpn(ip, provider) do
    sql = """
    ALTER TABLE events UPDATE
      ip_vpn_provider = #{Spectabas.ClickHouse.param(provider)},
      ip_is_vpn = 1
    WHERE ip_address = #{Spectabas.ClickHouse.param(ip)}
    SETTINGS mutations_sync = 0
    """

    case Spectabas.ClickHouse.execute(sql) do
      :ok -> :ok
      {:error, e} -> Logger.warning("[BackfillVpn] Update failed for #{ip}: #{inspect(e)}")
    end
  end

  # For non-VPN IPs, set ip_vpn_provider to a sentinel so they don't get
  # re-queried in the next batch. Uses a single space — empty string is
  # the "not yet checked" marker.
  defp mark_checked(ip) do
    sql = """
    ALTER TABLE events UPDATE
      ip_vpn_provider = ' '
    WHERE ip_address = #{Spectabas.ClickHouse.param(ip)} AND ip_vpn_provider = ''
    SETTINGS mutations_sync = 0
    """

    Spectabas.ClickHouse.execute(sql)
  end
end
