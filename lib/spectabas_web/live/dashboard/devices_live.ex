defmodule SpectabasWeb.Dashboard.DevicesLive do
  use SpectabasWeb, :live_view

  @moduledoc "Device type, browser, and OS breakdown with tabs and pie chart."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Devices - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:tab, "device_type")
        |> assign(:loading, true)
        |> assign(:devices, [])
        |> assign(:total_visitors, 0)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:tab, tab) |> assign(:loading, true)}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_devices() |> assign(:loading, false)}
  end

  defp load_devices(socket) do
    %{site: site, user: user, date_range: range, tab: tab} = socket.assigns
    period = range_to_period(range)

    devices =
      case tab do
        "browser" ->
          case Analytics.top_browsers(site, user, period) do
            {:ok, rows} -> Enum.map(rows, &Map.put(&1, "browser", &1["name"]))
            _ -> []
          end

        "os" ->
          case Analytics.top_os(site, user, period) do
            {:ok, rows} -> Enum.map(rows, &Map.put(&1, "os", &1["name"]))
            _ -> []
          end

        _ ->
          case Analytics.top_device_types(site, user, period) do
            {:ok, rows} -> rows
            _ -> []
          end
      end

    # Compute percentages
    total = Enum.reduce(devices, 0, fn d, acc -> acc + to_num(d["unique_visitors"]) end)

    devices =
      Enum.map(devices, fn d ->
        visitors = to_num(d["unique_visitors"])
        pct = if total > 0, do: Float.round(visitors / total * 100, 1), else: 0.0
        Map.put(d, "pct", pct)
      end)

    # Push pie chart data
    labels = Enum.map(devices, &(Map.get(&1, tab, "Unknown") || "Unknown"))
    values = Enum.map(devices, &to_num(&1["unique_visitors"]))

    socket = socket |> assign(:devices, devices) |> assign(:total_visitors, total)

    if connected?(socket) do
      push_event(socket, "pie-data", %{labels: Enum.take(labels, 8), values: Enum.take(values, 8)})
    else
      socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Devices"
      page_description="Browser, OS, and device type breakdown."
      active="devices"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Devices</h1>
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

        <div class="mb-6 flex gap-2">
          <button
            :for={
              {id, label} <- [{"device_type", "Device Type"}, {"browser", "Browser"}, {"os", "OS"}]
            }
            phx-click="change_tab"
            phx-value-tab={id}
            class={[
              "px-4 py-2 text-sm font-medium rounded-md",
              if(@tab == id,
                do: "bg-indigo-600 text-white",
                else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
              )
            ]}
          >
            {label}
          </button>
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
          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <%!-- Pie Chart --%>
            <div :if={@devices != []} class="bg-white rounded-lg shadow p-6">
              <div id="pie-chart" phx-hook="PieChart" class="h-64">
                <canvas></canvas>
              </div>
            </div>

            <%!-- Table --%>
            <div class={[
              "bg-white rounded-lg shadow overflow-x-auto",
              if(@devices != [], do: "lg:col-span-2", else: "lg:col-span-3")
            ]}>
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                      {String.replace(@tab, "_", " ") |> String.capitalize()}
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Visitors
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                      %
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                      Pageviews
                    </th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-gray-200">
                  <tr :if={@devices == []}>
                    <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                      No data for this period.
                    </td>
                  </tr>
                  <tr :for={device <- @devices} class="hover:bg-gray-50">
                    <td class="px-6 py-4 text-sm text-gray-900 font-medium">
                      {Map.get(device, @tab, "Unknown") || "Unknown"}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(device["unique_visitors"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-500 text-right tabular-nums">
                      {device["pct"]}%
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(device["pageviews"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end
end
