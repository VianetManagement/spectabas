defmodule SpectabasWeb.Dashboard.EventsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Custom events fired via Spectabas.track(), excluding internal events."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Events - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "30d")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns

    events =
      safe_query(fn -> Analytics.custom_events(site, user, range_to_period(range)) end)

    assign(socket, :events, events)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Custom Events"
      page_description="Custom events fired via Spectabas.track(), excluding internal events."
      active="events"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Custom Events</h1>
            <p class="text-sm text-gray-500 mt-1">
              All custom events fired via <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">Spectabas.track()</code>.
              Internal events (prefixed with _) are hidden.
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7 days"}, {"30d", "30 days"}]}
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

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Event Name
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Hits
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200">
              <tr :if={@events == []}>
                <td colspan="3" class="px-6 py-8 text-center text-gray-500">
                  No custom events found. Use
                  <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">
                    Spectabas.track("event_name", {"{props}"})
                  </code>
                  to send custom events from your site.
                </td>
              </tr>
              <tr :for={ev <- @events} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-medium text-gray-900">{ev["event_name"]}</td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(ev["hits"]))}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(ev["visitors"]))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
