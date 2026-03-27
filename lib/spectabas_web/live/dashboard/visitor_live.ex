defmodule SpectabasWeb.Dashboard.VisitorLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Visitors, Analytics}

  @impl true
  def mount(%{"site_id" => site_id, "visitor_id" => visitor_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      visitor = Visitors.get_visitor!(visitor_id)

      timeline =
        case Analytics.visitor_timeline(site, visitor_id) do
          {:ok, events} -> events
          _ -> []
        end

      {:ok,
       socket
       |> assign(:page_title, "Visitor - #{site.name}")
       |> assign(:site, site)
       |> assign(:visitor, visitor)
       |> assign(:timeline, timeline)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/visitors"}
          class="text-sm text-indigo-600 hover:text-indigo-800"
        >
          &larr; Back to Visitors
        </.link>
        <h1 class="text-2xl font-bold text-gray-900 mt-2">Visitor Profile</h1>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
        <%!-- Identity Card --%>
        <div class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Identity</h2>
          <dl class="space-y-3">
            <div>
              <dt class="text-xs font-medium text-gray-500 uppercase">Visitor ID</dt>
              <dd class="mt-1 text-sm text-gray-900 font-mono">{@visitor.id}</dd>
            </div>
            <div :if={@visitor.email}>
              <dt class="text-xs font-medium text-gray-500 uppercase">Email</dt>
              <dd class="mt-1 text-sm text-gray-900">{@visitor.email}</dd>
            </div>
            <div :if={@visitor.user_id}>
              <dt class="text-xs font-medium text-gray-500 uppercase">User ID</dt>
              <dd class="mt-1 text-sm text-gray-900 font-mono">{@visitor.user_id}</dd>
            </div>
            <div>
              <dt class="text-xs font-medium text-gray-500 uppercase">First Seen</dt>
              <dd class="mt-1 text-sm text-gray-900">{format_datetime(@visitor.first_seen_at)}</dd>
            </div>
            <div>
              <dt class="text-xs font-medium text-gray-500 uppercase">Last Seen</dt>
              <dd class="mt-1 text-sm text-gray-900">{format_datetime(@visitor.last_seen_at)}</dd>
            </div>
            <div>
              <dt class="text-xs font-medium text-gray-500 uppercase">GDPR Mode</dt>
              <dd class="mt-1">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(@visitor.gdpr_mode == "on",
                    do: "bg-green-100 text-green-800",
                    else: "bg-gray-100 text-gray-800"
                  )
                ]}>
                  {@visitor.gdpr_mode}
                </span>
              </dd>
            </div>
          </dl>
        </div>

        <%!-- IP History Card --%>
        <div class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">IP History</h2>
          <div :if={@visitor.last_ip} class="mb-3">
            <dt class="text-xs font-medium text-gray-500 uppercase">Last IP</dt>
            <dd class="mt-1 text-sm text-gray-900 font-mono">{format_ip(@visitor.last_ip)}</dd>
          </div>
          <div :if={@visitor.known_ips != []}>
            <dt class="text-xs font-medium text-gray-500 uppercase mb-2">Known IPs</dt>
            <ul class="space-y-1">
              <li :for={ip <- @visitor.known_ips} class="text-sm text-gray-700 font-mono">
                {ip}
              </li>
            </ul>
          </div>
          <p :if={@visitor.known_ips == [] && !@visitor.last_ip} class="text-sm text-gray-500">
            No IP data available.
          </p>
        </div>

        <%!-- Sessions Summary Card --%>
        <div class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Summary</h2>
          <dl class="space-y-3">
            <div>
              <dt class="text-xs font-medium text-gray-500 uppercase">Total Events</dt>
              <dd class="mt-1 text-2xl font-bold text-gray-900">{length(@timeline)}</dd>
            </div>
            <div>
              <dt class="text-xs font-medium text-gray-500 uppercase">Identification</dt>
              <dd class="mt-1 text-sm text-gray-900">
                {if @visitor.cookie_id, do: "Cookie", else: "Fingerprint"}
              </dd>
            </div>
          </dl>
        </div>
      </div>

      <%!-- Event Timeline --%>
      <div class="bg-white rounded-lg shadow">
        <div class="px-6 py-4 border-b border-gray-200">
          <h2 class="text-lg font-semibold text-gray-900">Event Timeline</h2>
        </div>
        <div :if={@timeline == []} class="px-6 py-8 text-center text-gray-500">
          No events recorded.
        </div>
        <ul class="divide-y divide-gray-100">
          <li :for={event <- @timeline} class="px-6 py-3 flex items-center justify-between">
            <div class="flex items-center gap-3">
              <span class={[
                "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                event_type_class(Map.get(event, "event_type", "pageview"))
              ]}>
                {Map.get(event, "event_type", "pageview")}
              </span>
              <span class="text-sm text-gray-900 truncate max-w-md">
                {Map.get(event, "url_path", "/")}
              </span>
              <span :if={name = Map.get(event, "event_name")} class="text-sm text-gray-500">
                ({name})
              </span>
            </div>
            <div class="flex items-center gap-4 text-xs text-gray-500">
              <span :if={country = Map.get(event, "ip_country")}>{country}</span>
              <span :if={browser = Map.get(event, "browser")}>{browser}</span>
              <span :if={org = Map.get(event, "ip_org")}>{org}</span>
              <span>{Map.get(event, "timestamp", "")}</span>
            </div>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_ip(%Postgrex.INET{address: addr}) do
    addr |> :inet.ntoa() |> to_string()
  end

  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: "-"

  defp event_type_class("pageview"), do: "bg-blue-100 text-blue-800"
  defp event_type_class("custom"), do: "bg-purple-100 text-purple-800"
  defp event_type_class("ecommerce_order"), do: "bg-green-100 text-green-800"
  defp event_type_class(_), do: "bg-gray-100 text-gray-800"
end
