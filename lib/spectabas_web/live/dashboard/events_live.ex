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

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Events - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:expanded_event, nil)
        |> assign(:event_properties, [])
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:date_range, range)
     |> assign(:expanded_event, nil)
     |> assign(:event_properties, [])
     |> assign(:loading, true)}
  end

  def handle_event("expand_event", %{"event" => event_name}, socket) do
    if socket.assigns.expanded_event == event_name do
      {:noreply, socket |> assign(:expanded_event, nil) |> assign(:event_properties, [])}
    else
      %{site: site, user: user, date_range: range} = socket.assigns

      props =
        safe_query(fn ->
          Analytics.event_properties(site, user, event_name, range_to_period(range))
        end)

      # Group by prop_key -> list of {prop_value, occurrences}
      grouped =
        props
        |> Enum.group_by(& &1["prop_key"])
        |> Enum.map(fn {key, vals} ->
          top_vals =
            Enum.map(vals, fn v -> %{value: v["prop_value"], count: to_num(v["occurrences"])} end)
            |> Enum.take(10)

          %{key: key, values: top_vals}
        end)
        |> Enum.sort_by(& &1.key)

      {:noreply,
       socket |> assign(:expanded_event, event_name) |> assign(:event_properties, grouped)}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
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

        <%= if @loading do %>
          <div class="bg-white rounded-lg shadow p-12 text-center">
            <div class="inline-flex items-center gap-3 text-gray-600">
              <svg class="animate-spin h-5 w-5 text-indigo-600" viewBox="0 0 24 24" fill="none">
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
              <span class="text-sm">Loading...</span>
            </div>
          </div>
        <% else %>
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
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Sessions
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Avg/Visitor
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200">
                <tr :if={@events == []}>
                  <td colspan="5" class="px-6 py-8 text-center text-gray-500">
                    No custom events found. Use
                    <code class="text-xs bg-gray-100 px-1 py-0.5 rounded">
                      Spectabas.track("event_name", {"{props}"})
                    </code>
                    to send custom events from your site.
                  </td>
                </tr>
                <%= for ev <- @events do %>
                  <tr
                    phx-click="expand_event"
                    phx-value-event={ev["event_name"]}
                    class={[
                      "hover:bg-gray-50 cursor-pointer",
                      @expanded_event == ev["event_name"] && "bg-indigo-50"
                    ]}
                  >
                    <td class="px-6 py-4 text-sm font-medium text-gray-900">
                      <div class="flex items-center gap-2">
                        <.icon
                          name={
                            if @expanded_event == ev["event_name"],
                              do: "hero-chevron-down",
                              else: "hero-chevron-right"
                          }
                          class="w-4 h-4 text-gray-400"
                        />
                        {ev["event_name"]}
                      </div>
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(ev["hits"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(ev["visitors"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                      {format_number(to_num(ev["sessions"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                      {ev["avg_per_visitor"]}
                    </td>
                  </tr>
                  <tr :if={@expanded_event == ev["event_name"]} class="bg-gray-50">
                    <td colspan="5" class="px-6 py-4">
                      <div :if={@event_properties == []} class="text-sm text-gray-500 italic">
                        No properties found for this event.
                      </div>
                      <div :if={@event_properties != []} class="space-y-4">
                        <div :for={prop <- @event_properties}>
                          <h4 class="text-xs font-semibold text-gray-700 uppercase tracking-wide mb-2">
                            {prop.key}
                          </h4>
                          <div class="flex flex-wrap gap-2">
                            <div
                              :for={v <- prop.values}
                              class="inline-flex items-center gap-1.5 px-2.5 py-1 bg-white border border-gray-200 rounded-lg text-xs"
                            >
                              <span class="text-gray-800 font-medium">{v.value}</span>
                              <span class="text-gray-400">{format_number(v.count)}</span>
                            </div>
                          </div>
                        </div>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end
end
