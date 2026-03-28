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
    events = [event | socket.assigns.events] |> Enum.take(20)

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
    <.dashboard_layout site={@site} active="realtime" live_visitors={0}>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Realtime</h1>
          </div>
        </div>

        <div class="bg-white rounded-lg shadow p-8 mb-8 text-center">
          <div class="flex items-center justify-center gap-3">
            <span class="w-3 h-3 bg-green-500 rounded-full animate-pulse"></span>
            <span class="text-5xl font-bold text-gray-900">{@active_count}</span>
          </div>
          <p class="text-gray-500 mt-2">visitors online right now</p>
        </div>

        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900">Live Event Feed</h2>
          </div>
          <div :if={@events == []} class="px-6 py-8 text-center text-gray-500">
            Waiting for events...
          </div>
          <ul class="divide-y divide-gray-100">
            <li :for={event <- @events} class="px-6 py-3 flex items-center justify-between">
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
              </div>
              <div class="flex items-center gap-4 text-sm text-gray-500">
                <span :if={country = Map.get(event, "ip_country")}>{country}</span>
                <span :if={browser = Map.get(event, "browser")}>{browser}</span>
                <span>{Map.get(event, "timestamp", "")}</span>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp event_type_class("pageview"), do: "bg-blue-100 text-blue-800"
  defp event_type_class("custom"), do: "bg-purple-100 text-purple-800"
  defp event_type_class(_), do: "bg-gray-100 text-gray-800"
end
