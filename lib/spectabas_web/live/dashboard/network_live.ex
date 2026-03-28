defmodule SpectabasWeb.Dashboard.NetworkLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Network - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> load_network()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_network()}
  end

  defp load_network(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns

    network =
      case Analytics.network_stats(site, user, range_to_atom(range)) do
        {:ok, rows} when is_list(rows) ->
          total_hits = Enum.reduce(rows, 0, fn r, acc -> acc + to_num(r["hits"]) end)

          avg_pct = fn key ->
            if total_hits > 0 do
              weighted =
                Enum.reduce(rows, 0.0, fn r, acc ->
                  acc + to_float(r[key]) * to_num(r["hits"])
                end)

              Float.round(weighted / total_hits, 1)
            else
              0.0
            end
          end

          %{
            asns: rows,
            datacenter_pct: avg_pct.("datacenter_pct"),
            vpn_pct: avg_pct.("vpn_pct"),
            tor_pct: avg_pct.("tor_pct"),
            bot_pct: avg_pct.("bot_pct")
          }

        _ ->
          %{asns: [], datacenter_pct: 0.0, vpn_pct: 0.0, tor_pct: 0.0, bot_pct: 0.0}
      end

    assign(socket, :network, network)
  end

  defp to_num(n) when is_integer(n), do: n

  defp to_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_num(_), do: 0

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <div>
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            &larr; Back to {@site.name}
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Network</h1>
        </div>
        <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
          <button
            :for={r <- [{"24h", "24h"}, {"7d", "7 days"}, {"30d", "30 days"}]}
            phx-click="change_range"
            phx-value-range={elem(r, 0)}
            class={[
              "px-3 py-1.5 text-sm font-medium rounded-md",
              if(@date_range == elem(r, 0),
                do: "bg-white shadow text-gray-900",
                else: "text-gray-600 hover:text-gray-900"
              )
            ]}
          >
            {elem(r, 1)}
          </button>
        </nav>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-sm font-medium text-gray-500">Datacenter</dt>
          <dd class="mt-1 text-2xl font-bold text-gray-900">{@network.datacenter_pct}%</dd>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-sm font-medium text-gray-500">VPN</dt>
          <dd class="mt-1 text-2xl font-bold text-gray-900">{@network.vpn_pct}%</dd>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-sm font-medium text-gray-500">Tor</dt>
          <dd class="mt-1 text-2xl font-bold text-gray-900">{@network.tor_pct}%</dd>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-sm font-medium text-gray-500">Bot</dt>
          <dd class="mt-1 text-2xl font-bold text-gray-900">{@network.bot_pct}%</dd>
        </div>
      </div>

      <div class="bg-white rounded-lg shadow overflow-hidden">
        <div class="px-6 py-4 border-b border-gray-200">
          <h2 class="text-lg font-semibold text-gray-900">Top ASNs</h2>
        </div>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                ASN
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Organization
              </th>
              <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                Visitors
              </th>
              <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase tracking-wider">
                Type
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :if={Map.get(@network, :asns, []) == []}>
              <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                No data for this period.
              </td>
            </tr>
            <tr :for={asn <- Map.get(@network, :asns, [])} class="hover:bg-gray-50">
              <td class="px-6 py-4 text-sm text-gray-900 font-mono">
                AS{Map.get(asn, "ip_asn", "")}
              </td>
              <td class="px-6 py-4 text-sm text-gray-900">
                {Map.get(asn, "ip_org", "Unknown")}
              </td>
              <td class="px-6 py-4 text-sm text-gray-900 text-right">
                {Map.get(asn, "hits", 0)}
              </td>
              <td class="px-6 py-4 text-center">
                <span
                  :if={to_float(asn["datacenter_pct"]) > 50}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"
                >
                  DC
                </span>
                <span
                  :if={to_float(asn["vpn_pct"]) > 50}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-orange-100 text-orange-800"
                >
                  VPN
                </span>
                <span
                  :if={to_float(asn["tor_pct"]) > 50}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800"
                >
                  Tor
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
