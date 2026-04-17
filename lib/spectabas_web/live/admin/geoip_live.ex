defmodule SpectabasWeb.Admin.GeoipLive do
  use SpectabasWeb, :live_view

  alias Spectabas.GeoIP.DownloadLog

  @impl true
  def mount(_params, _session, socket) do
    databases = current_database_status()
    recent = DownloadLog.recent(50)
    latest = DownloadLog.latest_per_database()

    {:ok,
     socket
     |> assign(:page_title, "GeoIP Databases")
     |> assign(:databases, databases)
     |> assign(:latest, latest)
     |> assign(:recent, recent)}
  end

  @impl true
  def handle_event("refresh_all", _params, socket) do
    Oban.insert(Spectabas.Workers.GeoIPRefresh.new(%{}))

    {:noreply,
     socket
     |> put_flash(:info, "Refresh all databases queued. Reload in a minute to see results.")}
  end

  def handle_event("refresh_provider", %{"provider" => provider}, socket) do
    Oban.insert(Spectabas.Workers.GeoIPRefresh.new(%{"provider" => provider}))

    {:noreply,
     socket
     |> put_flash(:info, "Refresh #{provider} queued. Reload in a minute to see results.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8 flex items-center justify-between">
        <div>
          <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
            &larr; Admin Dashboard
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">GeoIP Databases</h1>
          <p class="text-sm text-gray-500 mt-1">
            External IP enrichment databases — auto-downloaded on boot and refreshed weekly (Monday 06:00 UTC).
          </p>
        </div>
        <button
          phx-click="refresh_all"
          class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
        >
          Refresh All
        </button>
      </div>

      <%!-- Current Database Status --%>
      <div class="bg-white rounded-lg shadow mb-8">
        <div class="px-5 py-4 border-b border-gray-100">
          <h2 class="font-semibold text-gray-900">Current Status</h2>
        </div>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Database
              </th>
              <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Provider
              </th>
              <th class="px-5 py-3 text-center text-xs font-medium text-gray-500 uppercase">
                Loaded
              </th>
              <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">Env Var</th>
              <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Last Download
              </th>
              <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={db <- @databases} class="hover:bg-gray-50">
              <td class="px-5 py-3 text-sm font-medium text-gray-900">{db.name}</td>
              <td class="px-5 py-3 text-sm text-gray-500">{db.provider}</td>
              <td class="px-5 py-3 text-center">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(db.loaded, do: "bg-green-100 text-green-800", else: "bg-gray-100 text-gray-500")
                ]}>
                  {if db.loaded, do: "Yes", else: "No"}
                </span>
              </td>
              <td class="px-5 py-3 text-xs text-gray-500 font-mono">{db.env_var}</td>
              <td class="px-5 py-3 text-xs text-gray-500">
                {last_download_for(db.log_name, @latest)}
              </td>
              <td class="px-5 py-3 text-right">
                <button
                  phx-click="refresh_provider"
                  phx-value-provider={db.provider_key}
                  class="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
                >
                  Re-download
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Download History --%>
      <div class="bg-white rounded-lg shadow">
        <div class="px-5 py-4 border-b border-gray-100">
          <h2 class="font-semibold text-gray-900">Download History</h2>
          <p class="text-xs text-gray-500 mt-0.5">Recent download attempts (last 50)</p>
        </div>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">Time</th>
              <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Database
              </th>
              <th class="px-5 py-3 text-center text-xs font-medium text-gray-500 uppercase">
                Status
              </th>
              <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">Size</th>
              <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                Duration
              </th>
              <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">Error</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :if={@recent == []}>
              <td colspan="6" class="px-5 py-8 text-center text-gray-500 text-sm">
                No downloads recorded yet. Click "Refresh Now" to trigger a download, or wait for the next scheduled run.
              </td>
            </tr>
            <tr :for={d <- @recent} class="hover:bg-gray-50">
              <td class="px-5 py-3 text-xs text-gray-500 whitespace-nowrap">
                {Calendar.strftime(d.inserted_at, "%Y-%m-%d %H:%M UTC")}
              </td>
              <td class="px-5 py-3 text-sm font-medium text-gray-900">{d.database_name}</td>
              <td class="px-5 py-3 text-center">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(d.status == "success",
                    do: "bg-green-100 text-green-800",
                    else: "bg-red-100 text-red-800"
                  )
                ]}>
                  {d.status}
                </span>
              </td>
              <td class="px-5 py-3 text-sm text-gray-900 text-right tabular-nums">
                {format_size(d.file_size)}
              </td>
              <td class="px-5 py-3 text-sm text-gray-500 text-right tabular-nums">
                {if d.duration_ms, do: "#{d.duration_ms}ms", else: "-"}
              </td>
              <td class="px-5 py-3 text-xs text-red-600 truncate max-w-xs">
                {d.error_message || "-"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp current_database_status do
    [
      %{
        name: "DB-IP City Lite",
        provider: "DB-IP (free)",
        loaded: Geolix.lookup({8, 8, 8, 8}, where: :city) != nil,
        env_var: "(auto)",
        log_name: "dbip-city-lite",
        provider_key: "dbip"
      },
      %{
        name: "DB-IP ASN Lite",
        provider: "DB-IP (free)",
        loaded: Geolix.lookup({8, 8, 8, 8}, where: :asn) != nil,
        env_var: "(auto)",
        log_name: "dbip-asn-lite",
        provider_key: "dbip"
      },
      %{
        name: "MaxMind GeoLite2-City",
        provider: "MaxMind (free w/ key)",
        loaded: Geolix.lookup({8, 8, 8, 8}, where: :maxmind_city) != nil,
        env_var: "MAXMIND_LICENSE_KEY",
        log_name: "maxmind-geolite2-city",
        provider_key: "maxmind"
      },
      %{
        name: "ipapi.is VPN (Enumerated)",
        provider: "ipapi.is ($79/mo)",
        loaded: geolix_db_loaded?(:vpn_enumerated),
        env_var: "IPAPI_API_KEY",
        log_name: "ipapi-vpn-enumerated",
        provider_key: "ipapi_vpn"
      },
      %{
        name: "ipapi.is VPN (Interpolated)",
        provider: "ipapi.is ($79/mo)",
        loaded: geolix_db_loaded?(:vpn_interpolated),
        env_var: "IPAPI_API_KEY",
        log_name: "ipapi-vpn-interpolated",
        provider_key: "ipapi_vpn"
      }
    ]
  end

  defp last_download_for(log_name, latest_list) do
    case Enum.find(latest_list, &(&1.database_name == log_name)) do
      %{inserted_at: at, status: status} ->
        "#{Calendar.strftime(at, "%Y-%m-%d %H:%M")} (#{status})"

      nil ->
        "Never"
    end
  end

  defp geolix_db_loaded?(db_id) do
    case Geolix.metadata(where: db_id) do
      %{} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp format_size(nil), do: "-"
  defp format_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp format_size(bytes) when bytes >= 1_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_size(bytes), do: "#{bytes} B"
end
