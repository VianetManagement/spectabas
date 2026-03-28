defmodule SpectabasWeb.Dashboard.RealtimeLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent

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
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Spectabas.PubSub, "site:#{site.id}")
      end

      active_count =
        case Analytics.realtime_visitors(site) do
          {:ok, count} -> count
          _ -> 0
        end

      recent_events =
        case Analytics.realtime_events(site) do
          {:ok, events} -> events
          _ -> []
        end

      {:ok,
       socket
       |> assign(:page_title, "Realtime - #{site.name}")
       |> assign(:site, site)
       |> assign(:active_count, active_count)
       |> assign(:events, recent_events)}
    end
  end

  @impl true
  def handle_info({:new_event, event}, socket) do
    events = [event | socket.assigns.events] |> Enum.take(30)

    active_count =
      case Analytics.realtime_visitors(socket.assigns.site) do
        {:ok, count} -> count
        _ -> socket.assigns.active_count
      end

    {:noreply,
     socket
     |> assign(:events, events)
     |> assign(:active_count, active_count)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Realtime"
      page_description="Live visitor activity from the last 5 minutes."
      active="realtime"
      live_visitors={@active_count}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <%!-- Active count hero --%>
        <div class="bg-white rounded-lg shadow p-6 mb-6 text-center">
          <div class="flex items-center justify-center gap-3">
            <span class="w-3 h-3 bg-green-500 rounded-full animate-pulse"></span>
            <span class="text-5xl font-bold text-gray-900">{@active_count}</span>
          </div>
          <p class="text-gray-500 mt-2">visitors online right now</p>
        </div>

        <%!-- Live event feed --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="font-semibold text-gray-900">Live Event Feed</h3>
          </div>
          <div :if={@events == []} class="px-5 py-8 text-center text-gray-500">
            Waiting for events...
          </div>
          <div class="divide-y divide-gray-50">
            <div :for={event <- @events} class="px-5 py-3">
              <div class="flex items-center justify-between mb-1">
                <div class="flex items-center gap-2 min-w-0">
                  <%!-- Event type badge --%>
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium shrink-0",
                    event_type_class(event["event_type"])
                  ]}>
                    {event["event_type"]}
                  </span>
                  <%!-- Page path (clickable to transitions) --%>
                  <.link
                    navigate={
                      ~p"/dashboard/sites/#{@site.id}/transitions?page=#{event["url_path"] || "/"}"
                    }
                    class="text-sm text-indigo-600 hover:text-indigo-800 font-mono truncate"
                  >
                    {event["url_path"] || "/"}
                  </.link>
                </div>
                <span class="text-xs text-gray-400 shrink-0 ml-3">{event["timestamp"]}</span>
              </div>
              <%!-- Visitor details row --%>
              <div class="flex items-center gap-3 text-xs text-gray-500 mt-1 flex-wrap">
                <%!-- Visitor ID (clickable to profile) --%>
                <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{event["visitor_id"]}"}
                  class="text-indigo-500 hover:text-indigo-700 font-mono"
                  title="View visitor profile"
                >
                  {String.slice(event["visitor_id"] || "", 0, 8)}
                </.link>
                <%!-- Location (clickable to geo) --%>
                <.link
                  :if={event["ip_country"] && event["ip_country"] != ""}
                  navigate={~p"/dashboard/sites/#{@site.id}/geo"}
                  class="hover:text-indigo-600"
                >
                  {event["ip_country"]}
                </.link>
                <%!-- Browser (clickable to devices) --%>
                <.link
                  :if={event["browser"] && event["browser"] != ""}
                  navigate={~p"/dashboard/sites/#{@site.id}/devices"}
                  class="hover:text-indigo-600"
                >
                  {event["browser"]}
                </.link>
                <%!-- Device type --%>
                <span :if={event["device_type"] && event["device_type"] != ""} class="text-gray-400">
                  {event["device_type"]}
                </span>
                <%!-- Referrer (clickable to sources) --%>
                <.link
                  :if={event["referrer_domain"] && event["referrer_domain"] != ""}
                  navigate={
                    ~p"/dashboard/sites/#{@site.id}/visitor-log?filter_field=referrer_domain&filter_value=#{event["referrer_domain"]}"
                  }
                  class="hover:text-indigo-600"
                >
                  via {event["referrer_domain"]}
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp event_type_class("pageview"), do: "bg-blue-100 text-blue-800"
  defp event_type_class("custom"), do: "bg-purple-100 text-purple-800"
  defp event_type_class("duration"), do: "bg-gray-100 text-gray-600"
  defp event_type_class(_), do: "bg-gray-100 text-gray-800"
end
