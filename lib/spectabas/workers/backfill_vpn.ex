defmodule Spectabas.Workers.BackfillVpn do
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Logger.notice("[BackfillVpn] Starting VPN provider backfill...")

    # Get distinct IPs that don't have VPN provider data yet
    sql = """
    SELECT DISTINCT ip_address
    FROM events
    WHERE ip_address != '' AND ip_vpn_provider = ''
    LIMIT 50000
    """

    case Spectabas.ClickHouse.query(sql, receive_timeout: 120_000) do
      {:ok, rows} ->
        ips = Enum.map(rows, & &1["ip_address"])
        Logger.notice("[BackfillVpn] Found #{length(ips)} distinct IPs to check")

        {tagged, skipped} =
          Enum.reduce(ips, {0, 0}, fn ip, {tagged, skipped} ->
            case lookup_vpn(ip) do
              "" ->
                {tagged, skipped + 1}

              provider ->
                update_vpn(ip, provider)
                {tagged + 1, skipped}
            end
          end)

        Logger.notice("[BackfillVpn] Done! Tagged #{tagged} IPs as VPN, #{skipped} non-VPN")
        :ok

      {:error, e} ->
        Logger.error("[BackfillVpn] Query failed: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end

  defp lookup_vpn(ip_string) do
    Spectabas.IPEnricher.vpn_provider_for_ip(ip_string)
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
