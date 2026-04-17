defmodule SpectabasWeb.Dashboard.MapLive do
  use SpectabasWeb, :live_view

  @moduledoc "Interactive world map with visitor location bubbles."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Visitor Map - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:loading, true)
        |> assign(:locations, [])
        |> assign(:timezones, [])
        |> assign(:map_data, %{points: []})
        |> assign(:map_chart_key, 0)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("zoom_map", %{"region" => region}, socket) do
    # Only push the zoom event — don't assign to avoid re-rendering which
    # destroys the chart hooks and loses their data
    {:noreply, push_event(socket, "map-zoom", %{region: region})}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    locations =
      case Analytics.visitor_locations(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    timezones =
      case Analytics.timezone_distribution(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    map_points = build_map_points(locations)

    socket
    |> assign(:locations, locations)
    |> assign(:timezones, timezones)
    |> assign(:map_data, %{points: map_points})
    |> assign(:map_chart_key, System.unique_integer([:positive]))
    |> push_chart_events(locations, timezones)
  end

  defp build_map_points(locations) do
    Enum.map(locations, fn loc ->
      %{
        lat: to_float(loc["ip_lat"]),
        lon: to_float(loc["ip_lon"]),
        visitors: to_num(loc["visitors"]),
        label: location_name(loc)
      }
    end)
  end

  defp push_chart_events(socket, locations, timezones) do
    if Phoenix.LiveView.connected?(socket) do
      socket
      |> push_event("map-data", %{
        points:
          Enum.map(locations, fn loc ->
            %{
              lat: to_float(loc["ip_lat"]),
              lon: to_float(loc["ip_lon"]),
              visitors: to_num(loc["visitors"]),
              label: location_name(loc)
            }
          end)
      })
      |> push_event("bar-data", %{
        labels: Enum.map(timezones, &short_tz(&1["timezone"])),
        values: Enum.map(timezones, &to_num(&1["visitors"]))
      })
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
      page_title="Visitor Map"
      page_description="Geographic visualization of visitor locations with timezone distribution."
      active="map"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Visitor Map & Timezones</h1>
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
          <%!-- Visitor Map --%>
          <div class="bg-white rounded-lg shadow p-5 mb-6">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-sm font-medium text-gray-500">Visitor Locations</h3>
              <div class="flex gap-1 flex-wrap">
                <button
                  :for={
                    {id, label} <- [
                      {"world", "World"},
                      {"north_america", "N. America"},
                      {"south_america", "S. America"},
                      {"europe", "Europe"},
                      {"asia", "Asia"},
                      {"africa", "Africa"},
                      {"oceania", "Oceania"},
                      {"us", "USA"}
                    ]
                  }
                  phx-click="zoom_map"
                  phx-value-region={id}
                  id={"map-btn-#{id}"}
                  class="px-2 py-1 text-xs rounded-md bg-gray-100 text-gray-600 hover:bg-gray-200 map-zoom-btn"
                >
                  {label}
                </button>
              </div>
            </div>
            <div
              id={"fullpage-map-hook-#{@map_chart_key}"}
              phx-hook="BubbleMap"
              phx-update="ignore"
              data-chart={Jason.encode!(@map_data)}
            >
              <div class="h-[250px] sm:h-[350px] lg:h-[450px]" style="position: relative;">
                <canvas></canvas>
              </div>
            </div>
          </div>

          <%!-- Timezone Distribution --%>
          <div class="bg-white rounded-lg shadow p-5 mb-6">
            <h3 class="text-sm font-medium text-gray-500 mb-4">Timezone Distribution</h3>
            <div id="fullpage-tz-hook" phx-hook="BarChart">
              <div style={"height: #{max(length(@timezones) * 32, 100)}px; position: relative;"}>
                <canvas></canvas>
              </div>
            </div>
          </div>

          <%!-- Location Table --%>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="font-semibold text-gray-900">Top Locations</h3>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Location
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Visitors
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200">
                <tr :if={@locations == []}>
                  <td colspan="2" class="px-6 py-8 text-center text-gray-500">
                    No location data yet.
                  </td>
                </tr>
                <tr :for={loc <- Enum.take(@locations, 30)} class="hover:bg-gray-50">
                  <td class="px-6 py-3 text-sm text-gray-900">{location_name(loc)}</td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(loc["visitors"]))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp location_name(loc) do
    city = loc["ip_city"] || ""
    region = loc["ip_region_name"] || ""
    country = loc["ip_country"] || ""
    parts = [city, region, country] |> Enum.reject(&(&1 == ""))
    if parts == [], do: "Unknown", else: Enum.join(parts, ", ")
  end

  defp short_tz(tz) when is_binary(tz) do
    case String.split(tz, "/") do
      [_, city | _] -> String.replace(city, "_", " ")
      _ -> tz
    end
  end

  defp short_tz(_), do: "Unknown"
end
