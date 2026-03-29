defmodule SpectabasWeb.Dashboard.VisitorLive do
  use SpectabasWeb, :live_view

  import SpectabasWeb.Dashboard.SidebarComponent

  alias Spectabas.{Accounts, Sites, Visitors, Analytics}

  @impl true
  def mount(%{"site_id" => site_id, "visitor_id" => visitor_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      visitor = Visitors.get_visitor!(visitor_id)

      timeline =
        case Analytics.visitor_timeline(site, visitor_id) do
          {:ok, events} -> events
          _ -> []
        end

      profile =
        case Analytics.visitor_profile(site, visitor_id) do
          {:ok, p} when is_map(p) -> p
          _ -> %{}
        end

      # Get IP details and co-visitors for the last known IP
      last_ip = visitor.last_ip || get_in(List.first(timeline) || %{}, ["ip_address"])

      {ip_info, ip_visitors} =
        if last_ip && last_ip != "" do
          ip_info =
            case Analytics.ip_details(site, last_ip) do
              {:ok, info} -> info
              _ -> nil
            end

          ip_visitors =
            case Analytics.visitors_by_ip(site, last_ip) do
              {:ok, rows} -> Enum.reject(rows, &(&1["visitor_id"] == visitor_id))
              _ -> []
            end

          {ip_info, ip_visitors}
        else
          {nil, []}
        end

      # Get visitors with same browser fingerprint
      fingerprint = profile["browser_fingerprint"]

      fp_visitors =
        if fingerprint && fingerprint != "" do
          case Analytics.visitors_by_fingerprint(site, fingerprint) do
            {:ok, rows} -> Enum.reject(rows, &(&1["visitor_id"] == visitor_id))
            _ -> []
          end
        else
          []
        end

      # Compute session list from timeline
      sessions =
        timeline
        |> Enum.group_by(& &1["session_id"])
        |> Enum.map(fn {sid, events} ->
          pageviews = Enum.filter(events, &(&1["event_type"] == "pageview"))

          %{
            session_id: sid,
            started: List.first(events)["timestamp"],
            pages: length(pageviews),
            entry: List.first(pageviews)["url_path"],
            exit: List.last(pageviews)["url_path"],
            referrer: List.first(events)["referrer_domain"],
            duration: events |> Enum.map(&to_num(&1["duration_s"])) |> Enum.max(fn -> 0 end)
          }
        end)
        |> Enum.sort_by(& &1.started, :desc)

      {:ok,
       socket
       |> assign(:page_title, "Visitor - #{site.name}")
       |> assign(:site, site)
       |> assign(:visitor, visitor)
       |> assign(:profile, profile)
       |> assign(:timeline, timeline)
       |> assign(:sessions, sessions)
       |> assign(:last_ip, last_ip)
       |> assign(:ip_info, ip_info)
       |> assign(:ip_visitors, ip_visitors)
       |> assign(:fp_visitors, fp_visitors)
       |> assign(:show_ip_panel, false)}
    end
  end

  @impl true
  def handle_event("toggle_ip_panel", _params, socket) do
    {:noreply, assign(socket, :show_ip_panel, !socket.assigns.show_ip_panel)}
  end

  defp to_num(n) when is_integer(n), do: n

  defp to_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_num(_), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout site={@site} active="visitor-log" live_visitors={0}>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/visitor-log"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            &larr; Visitor Log
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Visitor Profile</h1>
        </div>

        <%!-- Top stats row --%>
        <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Pageviews</dt>
            <dd class="mt-1 text-2xl font-bold text-gray-900">{@profile["total_pageviews"] || 0}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Sessions</dt>
            <dd class="mt-1 text-2xl font-bold text-gray-900">{@profile["total_sessions"] || 0}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">First Seen</dt>
            <dd class="mt-1 text-sm font-bold text-gray-900">{@profile["first_seen"] || "-"}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Last Seen</dt>
            <dd class="mt-1 text-sm font-bold text-gray-900">{@profile["last_seen"] || "-"}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Duration</dt>
            <dd class="mt-1 text-2xl font-bold text-gray-900">
              {format_duration(@profile["total_duration"])}
            </dd>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-6">
          <%!-- Identity & Device --%>
          <div class="bg-white rounded-lg shadow p-5">
            <h3 class="text-sm font-semibold text-gray-700 mb-3 uppercase">Identity & Device</h3>
            <dl class="space-y-2 text-sm">
              <.field
                label="Visitor ID"
                value={String.slice(to_string(@visitor.id), 0, 12) <> "..."}
                mono={true}
              />
              <.field :if={@visitor.email} label="Email" value={@visitor.email} />
              <.field :if={@visitor.user_id} label="User ID" value={@visitor.user_id} mono={true} />
              <.field
                label="Browser"
                value={"#{@profile["browser"] || "?"} #{@profile["browser_version"] || ""}"}
              />
              <.field label="OS" value={"#{@profile["os"] || "?"} #{@profile["os_version"] || ""}"} />
              <.field label="Device" value={@profile["device_type"] || "Unknown"} />
              <.field
                label="Screen"
                value={"#{@profile["screen_width"] || "?"}x#{@profile["screen_height"] || "?"}"}
              />
              <.field
                label="ID Type"
                value={if @visitor.cookie_id, do: "Cookie", else: "Fingerprint"}
              />
              <.field label="GDPR Mode" value={@site.gdpr_mode || "on"} />
              <div :if={@profile["browser_fingerprint"] && @profile["browser_fingerprint"] != ""}>
                <dt class="text-xs font-medium text-gray-500">Browser Fingerprint</dt>
                <dd class="mt-0.5 text-xs text-indigo-600 font-mono">
                  {@profile["browser_fingerprint"]}
                  <span :if={@fp_visitors != []} class="text-amber-600 ml-1">
                    ({length(@fp_visitors)} other visitors share this fingerprint)
                  </span>
                </dd>
              </div>
              <div :if={@profile["user_agent"] && @profile["user_agent"] != ""}>
                <dt class="text-xs font-medium text-gray-500">User Agent</dt>
                <dd class="mt-0.5 text-xs text-gray-600 font-mono break-all leading-relaxed">
                  {@profile["user_agent"]}
                </dd>
              </div>
            </dl>
          </div>

          <%!-- Location & Network --%>
          <div class="bg-white rounded-lg shadow p-5">
            <h3 class="text-sm font-semibold text-gray-700 mb-3 uppercase">Location & Network</h3>
            <dl class="space-y-2 text-sm">
              <.field
                label="Country"
                value={"#{@profile["country_name"] || ""} (#{@profile["country"] || "?"})"}
              />
              <.field label="Region" value={@profile["region"] || "-"} />
              <.field label="City" value={@profile["city"] || "-"} />
              <.field label="Timezone" value={@profile["timezone"] || "-"} />
              <.field label="ISP / Org" value={@profile["org"] || "-"} />
              <div class="flex gap-2 pt-1">
                <span
                  :if={@profile["is_datacenter"] == "1" || @profile["is_datacenter"] == 1}
                  class="px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"
                >
                  Datacenter
                </span>
                <span
                  :if={@profile["is_vpn"] == "1" || @profile["is_vpn"] == 1}
                  class="px-2 py-0.5 rounded text-xs font-medium bg-orange-100 text-orange-800"
                >
                  VPN
                </span>
                <span
                  :if={@profile["is_bot"] == "1" || @profile["is_bot"] == 1}
                  class="px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800"
                >
                  Bot
                </span>
              </div>
            </dl>
          </div>

          <%!-- Acquisition & Behavior --%>
          <div class="bg-white rounded-lg shadow p-5">
            <h3 class="text-sm font-semibold text-gray-700 mb-3 uppercase">Acquisition & Behavior</h3>
            <dl class="space-y-2 text-sm">
              <.field label="Original Referrer" value={@profile["original_referrer"] || "Direct"} />
              <.field label="First Page" value={@profile["first_page"] || "-"} mono={true} />
              <.field label="Last Page" value={@profile["last_page"] || "-"} mono={true} />
              <div :if={@profile["utm_sources"] && @profile["utm_sources"] != []}>
                <dt class="text-xs font-medium text-gray-500">UTM Sources</dt>
                <dd class="mt-0.5 flex flex-wrap gap-1">
                  <span
                    :for={src <- List.wrap(@profile["utm_sources"])}
                    class="px-2 py-0.5 rounded text-xs bg-indigo-50 text-indigo-700"
                  >
                    {src}
                  </span>
                </dd>
              </div>
              <div :if={@profile["top_pages"] && @profile["top_pages"] != []}>
                <dt class="text-xs font-medium text-gray-500">Top Pages</dt>
                <dd class="mt-0.5 space-y-0.5">
                  <div
                    :for={page <- List.wrap(@profile["top_pages"])}
                    class="text-xs font-mono text-gray-600 truncate"
                  >
                    {page}
                  </div>
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <%!-- IP Details Panel --%>
        <div :if={@last_ip} class="bg-white rounded-lg shadow mb-6">
          <button
            phx-click="toggle_ip_panel"
            class="w-full px-5 py-4 flex items-center justify-between text-left"
          >
            <div>
              <h3 class="text-sm font-semibold text-gray-700">
                IP Address: <span class="font-mono text-indigo-600">{@last_ip}</span>
              </h3>
              <p class="text-xs text-gray-500 mt-0.5">
                {length(@ip_visitors)} other visitor(s) from this IP {if @ip_info,
                  do:
                    " &middot; #{@ip_info["ip_city"]}, #{@ip_info["ip_region_name"]}, #{@ip_info["ip_country"]}",
                  else: ""}
              </p>
            </div>
            <span class="text-gray-500 text-sm">
              {if @show_ip_panel, do: "Hide", else: "Show details"}
            </span>
          </button>

          <div :if={@show_ip_panel} class="border-t border-gray-100 px-5 py-4">
            <%!-- IP enrichment details --%>
            <div :if={@ip_info} class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
              <.field
                label="Country"
                value={"#{@ip_info["ip_country_name"]} (#{@ip_info["ip_country"]})"}
              />
              <.field label="Region" value={@ip_info["ip_region_name"] || "-"} />
              <.field label="City" value={@ip_info["ip_city"] || "-"} />
              <.field label="Postal Code" value={@ip_info["ip_postal_code"] || "-"} />
              <.field label="Continent" value={@ip_info["ip_continent_name"] || "-"} />
              <.field label="Timezone" value={@ip_info["ip_timezone"] || "-"} />
              <.field label="Lat / Lon" value={"#{@ip_info["ip_lat"]}, #{@ip_info["ip_lon"]}"} />
              <.field label="ASN" value={"AS#{@ip_info["ip_asn"]} #{@ip_info["ip_asn_org"]}"} />
            </div>

            <%!-- Other visitors from same IP --%>
            <div :if={@ip_visitors != []}>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">
                Other visitors from this IP
              </h4>
              <table class="min-w-full divide-y divide-gray-200 text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-3 py-2 text-left text-xs text-gray-500">Visitor</th>
                    <th class="px-3 py-2 text-left text-xs text-gray-500">Last Seen</th>
                    <th class="px-3 py-2 text-right text-xs text-gray-500">Pages</th>
                    <th class="px-3 py-2 text-left text-xs text-gray-500">Device</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :for={v <- @ip_visitors} class="hover:bg-gray-50">
                    <td class="px-3 py-2">
                      <.link
                        navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                        class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                      >
                        {String.slice(v["visitor_id"] || "", 0, 10)}...
                      </.link>
                    </td>
                    <td class="px-3 py-2 text-gray-500 text-xs">{v["last_seen"]}</td>
                    <td class="px-3 py-2 text-gray-900 text-right tabular-nums">{v["pageviews"]}</td>
                    <td class="px-3 py-2 text-gray-500 text-xs">
                      {[v["browser"], v["os"]]
                      |> Enum.reject(&(&1 == "" || is_nil(&1)))
                      |> Enum.join(" / ")}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Known IPs --%>
            <div :if={@visitor.known_ips != [] && length(@visitor.known_ips) > 1} class="mt-4">
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">All known IPs</h4>
              <div class="flex flex-wrap gap-2">
                <span
                  :for={ip <- @visitor.known_ips}
                  class="px-2 py-1 rounded text-xs font-mono bg-gray-100 text-gray-700"
                >
                  {ip}
                </span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Session History --%>
        <div class="bg-white rounded-lg shadow mb-6">
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="text-sm font-semibold text-gray-700">Sessions ({length(@sessions)})</h3>
          </div>
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Started</th>
                <th class="px-4 py-2 text-right text-xs text-gray-500">Pages</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Entry</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Exit</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Referrer</th>
                <th class="px-4 py-2 text-right text-xs text-gray-500">Duration</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={s <- @sessions} class="hover:bg-gray-50">
                <td class="px-4 py-2 text-gray-500 text-xs">{s.started}</td>
                <td class="px-4 py-2 text-gray-900 text-right tabular-nums">{s.pages}</td>
                <td class="px-4 py-2 text-gray-700 font-mono text-xs truncate max-w-[150px]">
                  {s.entry}
                </td>
                <td class="px-4 py-2 text-gray-700 font-mono text-xs truncate max-w-[150px]">
                  {s.exit}
                </td>
                <td class="px-4 py-2 text-gray-500 text-xs truncate max-w-[120px]">
                  {s.referrer || "Direct"}
                </td>
                <td class="px-4 py-2 text-gray-900 text-right tabular-nums">
                  {format_duration(s.duration)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Browser Fingerprint Cross-Reference --%>
        <div :if={@fp_visitors != []} class="bg-white rounded-lg shadow mb-6">
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="text-sm font-semibold text-gray-700">
              Same Browser Fingerprint ({length(@fp_visitors)} other visitors)
            </h3>
            <p class="text-xs text-gray-500 mt-0.5">
              These visitors share the same browser fingerprint — possible alt accounts or shared device.
            </p>
          </div>
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-3 py-2 text-left text-xs text-gray-500">Visitor</th>
                <th class="px-3 py-2 text-left text-xs text-gray-500">Last Seen</th>
                <th class="px-3 py-2 text-right text-xs text-gray-500">Pages</th>
                <th class="px-3 py-2 text-left text-xs text-gray-500">IP</th>
                <th class="px-3 py-2 text-left text-xs text-gray-500">Location</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={v <- @fp_visitors} class="hover:bg-gray-50">
                <td class="px-3 py-2">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {String.slice(v["visitor_id"] || "", 0, 10)}...
                  </.link>
                </td>
                <td class="px-3 py-2 text-gray-500 text-xs">{v["last_seen"]}</td>
                <td class="px-3 py-2 text-gray-900 text-right tabular-nums">{v["pageviews"]}</td>
                <td class="px-3 py-2 text-gray-500 font-mono text-xs">{v["ip_address"]}</td>
                <td class="px-3 py-2 text-gray-500 text-xs">
                  {[v["city"], v["country"]]
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(", ")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Event Timeline --%>
        <div class="bg-white rounded-lg shadow">
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="text-sm font-semibold text-gray-700">
              Event Timeline ({length(@timeline)} events)
            </h3>
          </div>
          <div :if={@timeline == []} class="px-5 py-8 text-center text-gray-500">
            No events recorded.
          </div>
          <ul class="divide-y divide-gray-50">
            <li
              :for={event <- @timeline}
              class="px-5 py-2.5 flex items-center justify-between text-sm"
            >
              <div class="flex items-center gap-3 min-w-0">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium shrink-0",
                  event_type_class(event["event_type"])
                ]}>
                  {event["event_type"]}
                </span>
                <span class="text-gray-900 truncate font-mono text-xs">{event["url_path"]}</span>
                <span
                  :if={event["event_name"] && event["event_name"] != ""}
                  class="text-gray-500 text-xs"
                >
                  ({event["event_name"]})
                </span>
                <span
                  :if={to_num(event["duration_s"]) > 0}
                  class="text-gray-500 text-xs"
                >
                  {format_duration(event["duration_s"])}
                </span>
              </div>
              <span class="text-xs text-gray-500 shrink-0 ml-4">{event["timestamp"]}</span>
            </li>
          </ul>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp field(assigns) do
    assigns = assigns |> Map.put_new(:mono, false)

    ~H"""
    <div>
      <dt class="text-xs font-medium text-gray-500">{@label}</dt>
      <dd class={["mt-0.5 text-gray-900", if(@mono, do: "font-mono text-xs", else: "")]}>
        {@value}
      </dd>
    </div>
    """
  end

  defp format_duration(s) when is_integer(s) and s > 0, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_duration(s) when is_binary(s), do: format_duration(to_num(s))
  defp format_duration(_), do: "-"

  defp event_type_class("pageview"), do: "bg-blue-100 text-blue-800"
  defp event_type_class("duration"), do: "bg-gray-100 text-gray-600"
  defp event_type_class("custom"), do: "bg-purple-100 text-purple-800"
  defp event_type_class("ecommerce_order"), do: "bg-green-100 text-green-800"
  defp event_type_class(_), do: "bg-gray-100 text-gray-800"
end
