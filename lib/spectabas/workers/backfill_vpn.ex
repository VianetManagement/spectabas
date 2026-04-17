defmodule Spectabas.Workers.BackfillVpn do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Spectabas.GeoIP.DownloadLog

  @batch_size 50000

  @impl Oban.Worker
  def perform(_job) do
    start = System.monotonic_time(:millisecond)
    Logger.notice("[BackfillVpn] Starting VPN provider backfill...")

    sql = """
    SELECT DISTINCT ip_address
    FROM events
    WHERE ip_address != '' AND ip_vpn_provider = ''
    LIMIT #{@batch_size}
    """

    case Spectabas.ClickHouse.query(sql, receive_timeout: 120_000) do
      {:ok, rows} ->
        total = length(rows)
        ips = Enum.map(rows, & &1["ip_address"])
        Logger.notice("[BackfillVpn] Found #{total} distinct IPs to check")

        {tagged, skipped, _} =
          Enum.reduce(ips, {0, 0, 0}, fn ip, {tagged, skipped, processed} ->
            processed = processed + 1

            if rem(processed, 5000) == 0 do
              Logger.notice("[BackfillVpn] Progress: #{processed}/#{total} (#{tagged} tagged)")
            end

            case Spectabas.IPEnricher.vpn_provider_for_ip(ip) do
              "" ->
                {tagged, skipped + 1, processed}

              provider ->
                update_vpn(ip, provider)
                {tagged + 1, skipped, processed}
            end
          end)

        ms = System.monotonic_time(:millisecond) - start

        Logger.notice(
          "[BackfillVpn] Done! #{tagged} VPN/relay IPs tagged, #{skipped} non-VPN, #{ms}ms"
        )

        DownloadLog.log_download("vpn-backfill", "success",
          file_size: tagged,
          duration_ms: ms,
          error_message: "#{total} IPs checked, #{tagged} tagged, #{skipped} non-VPN"
        )

        :ok

      {:error, e} ->
        ms = System.monotonic_time(:millisecond) - start
        Logger.error("[BackfillVpn] Query failed: #{inspect(e)}")

        DownloadLog.log_download("vpn-backfill", "error",
          error_message: inspect(e),
          duration_ms: ms
        )

        {:error, inspect(e)}
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
end
