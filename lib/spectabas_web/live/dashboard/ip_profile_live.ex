defmodule SpectabasWeb.Dashboard.IpProfileLive do
  @moduledoc "IP address profile — full geo, network, and all visitors who used this IP."

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id, "ip" => ip}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      ip_info =
        case Analytics.ip_details(site, ip) do
          {:ok, info} -> info
          _ -> nil
        end

      visitors =
        case Analytics.visitors_by_ip(site, ip) do
          {:ok, rows} -> rows
          _ -> []
        end

      page_hits =
        case Analytics.ip_page_hits(site, ip) do
          {:ok, rows} -> rows
          _ -> []
        end

      {:ok,
       socket
       |> assign(:page_title, "IP #{ip} - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:ip, ip)
       |> assign(:ip_info, ip_info)
       |> assign(:visitors, visitors)
       |> assign(:page_hits, page_hits)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title={"IP: #{@ip}"}
      page_description="All data for this IP address."
      active="visitor-log"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/visitor-log?ip=#{@ip}"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            &larr; Back to Visitor Log
          </.link>
        </div>

        <h1 class="text-2xl font-bold text-gray-900 mb-6 font-mono">{@ip}</h1>

        <%!-- IP Details — all available data --%>
        <div :if={@ip_info} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">IP Enrichment Data</h2>

          <%!-- Badges --%>
          <div class="flex gap-2 mb-5">
            <span
              :if={@ip_info["ip_is_datacenter"] in ["1", 1]}
              class="text-xs bg-orange-100 text-orange-700 px-2 py-1 rounded font-medium"
            >
              Datacenter
            </span>
            <span
              :if={@ip_info["ip_is_vpn"] in ["1", 1]}
              class="text-xs bg-yellow-100 text-yellow-700 px-2 py-1 rounded font-medium"
            >
              VPN
            </span>
            <span
              :if={@ip_info["ip_is_tor"] in ["1", 1]}
              class="text-xs bg-red-100 text-red-700 px-2 py-1 rounded font-medium"
            >
              Tor
            </span>
            <span
              :if={@ip_info["ip_is_bot"] in ["1", 1]}
              class="text-xs bg-red-100 text-red-700 px-2 py-1 rounded font-medium"
            >
              Bot
            </span>
            <span
              :if={@ip_info["ip_is_eu"] in ["1", 1]}
              class="text-xs bg-blue-100 text-blue-700 px-2 py-1 rounded font-medium"
            >
              EU
            </span>
          </div>

          <%!-- Location --%>
          <h3 class="text-sm font-semibold text-gray-700 mb-3 mt-4">Location</h3>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-3">
            <.ip_field label="City" value={@ip_info["ip_city"]} />
            <.ip_field label="Region" value={@ip_info["ip_region_name"]} />
            <.ip_field label="Region Code" value={@ip_info["ip_region_code"]} />
            <.ip_field label="Country" value={@ip_info["ip_country_name"]} />
            <.ip_field label="Country Code" value={@ip_info["ip_country"]} />
            <.ip_field label="Continent" value={@ip_info["ip_continent_name"]} />
            <.ip_field label="Continent Code" value={@ip_info["ip_continent"]} />
            <.ip_field label="Postal Code" value={@ip_info["ip_postal_code"]} />
          </div>

          <%!-- Coordinates --%>
          <h3 class="text-sm font-semibold text-gray-700 mb-3 mt-5">Coordinates</h3>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-3">
            <.ip_field label="Latitude" value={@ip_info["ip_lat"]} />
            <.ip_field label="Longitude" value={@ip_info["ip_lon"]} />
            <.ip_field label="Accuracy Radius" value={@ip_info["ip_accuracy_radius"]} suffix="km" />
            <.ip_field label="Timezone" value={@ip_info["ip_timezone"]} />
          </div>

          <%!-- Network --%>
          <h3 class="text-sm font-semibold text-gray-700 mb-3 mt-5">Network</h3>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-3">
            <.ip_field label="ASN" value={@ip_info["ip_asn"]} />
            <.ip_field label="ASN Organization" value={@ip_info["ip_asn_org"]} />
            <.ip_field label="Organization" value={@ip_info["ip_org"]} />
          </div>
        </div>

        <div :if={!@ip_info} class="bg-white rounded-lg shadow p-6 mb-6">
          <p class="text-sm text-gray-500">No enrichment data available for this IP address.</p>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Visitors --%>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-6 py-4 border-b border-gray-100">
              <h2 class="font-semibold text-gray-900">Visitors ({length(@visitors)})</h2>
              <p class="text-xs text-gray-500 mt-0.5">All visitors who have used this IP</p>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Visitor
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Pageviews
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Browser / OS
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Last Seen
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@visitors == []}>
                  <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                    No visitors found.
                  </td>
                </tr>
                <tr :for={v <- @visitors} class="hover:bg-gray-50">
                  <td class="px-6 py-3 text-sm">
                    <.link
                      navigate={
                        ~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}?ip=#{@ip}"
                      }
                      class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                    >
                      {String.slice(v["visitor_id"] || "", 0, 12)}...
                    </.link>
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(v["pageviews"]))}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-500">
                    {v["browser"]} / {v["os"]}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-500 text-xs">{v["last_seen"]}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Top Pages Hit from This IP --%>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-6 py-4 border-b border-gray-100">
              <h2 class="font-semibold text-gray-900">Pages Visited</h2>
              <p class="text-xs text-gray-500 mt-0.5">Top pages accessed from this IP</p>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Page
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Hits
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@page_hits == []}>
                  <td colspan="2" class="px-6 py-8 text-center text-gray-500">
                    No page data.
                  </td>
                </tr>
                <tr :for={p <- @page_hits} class="hover:bg-gray-50">
                  <td class="px-6 py-3 text-sm text-indigo-600 font-mono truncate max-w-xs">
                    <.link navigate={
                      ~p"/dashboard/sites/#{@site.id}/transitions?page=#{p["url_path"]}"
                    }>
                      {p["url_path"]}
                    </.link>
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(p["hits"]))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp ip_field(assigns) do
    assigns = Map.put_new(assigns, :suffix, nil)

    ~H"""
    <div>
      <div class="text-[10px] font-medium text-gray-400 uppercase tracking-wider">{@label}</div>
      <div class="text-sm text-gray-900 mt-0.5">
        {display_value(@value)}{if @suffix && display_value(@value) != "—",
          do: " #{@suffix}",
          else: ""}
      </div>
    </div>
    """
  end

  defp display_value(nil), do: "—"
  defp display_value(""), do: "—"
  defp display_value("0"), do: "—"
  defp display_value(0), do: "—"
  defp display_value(v) when is_float(v) and v == 0.0, do: "—"
  defp display_value(v), do: to_string(v)
end
