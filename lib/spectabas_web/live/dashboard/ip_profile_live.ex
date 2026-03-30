defmodule SpectabasWeb.Dashboard.IpProfileLive do
  @moduledoc "IP address profile — geo, network, and all visitors who used this IP."

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id, "ip" => ip}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
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

        <%!-- IP Details --%>
        <div :if={@ip_info} class="bg-white rounded-lg shadow p-6 mb-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">IP Details</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <div class="text-xs font-medium text-gray-500 uppercase">Location</div>
              <div class="text-sm text-gray-900 mt-1">
                {[@ip_info["city"], @ip_info["region"], @ip_info["country"]]
                |> Enum.reject(&(&1 == "" || is_nil(&1)))
                |> Enum.join(", ")}
              </div>
            </div>
            <div>
              <div class="text-xs font-medium text-gray-500 uppercase">Organization</div>
              <div class="text-sm text-gray-900 mt-1">{@ip_info["org"] || "Unknown"}</div>
            </div>
            <div>
              <div class="text-xs font-medium text-gray-500 uppercase">ASN</div>
              <div class="text-sm text-gray-900 mt-1">{@ip_info["asn"] || "Unknown"}</div>
            </div>
            <div>
              <div class="text-xs font-medium text-gray-500 uppercase">Timezone</div>
              <div class="text-sm text-gray-900 mt-1">{@ip_info["timezone"] || "Unknown"}</div>
            </div>
          </div>
          <div class="flex gap-2 mt-4">
            <span
              :if={@ip_info["is_datacenter"] == "1"}
              class="text-xs bg-orange-100 text-orange-700 px-2 py-1 rounded"
            >
              Datacenter
            </span>
            <span
              :if={@ip_info["is_vpn"] == "1"}
              class="text-xs bg-yellow-100 text-yellow-700 px-2 py-1 rounded"
            >
              VPN
            </span>
            <span
              :if={@ip_info["is_tor"] == "1"}
              class="text-xs bg-red-100 text-red-700 px-2 py-1 rounded"
            >
              Tor
            </span>
            <span
              :if={@ip_info["is_bot"] == "1"}
              class="text-xs bg-red-100 text-red-700 px-2 py-1 rounded"
            >
              Bot
            </span>
            <span
              :if={@ip_info["is_eu"] == "1"}
              class="text-xs bg-blue-100 text-blue-700 px-2 py-1 rounded"
            >
              EU
            </span>
          </div>
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
                    {v["pageviews"]}
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
                    {p["hits"]}
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
end
