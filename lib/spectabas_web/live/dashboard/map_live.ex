defmodule SpectabasWeb.Dashboard.MapLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Visitor Map - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_atom(range)

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

    socket
    |> assign(:locations, locations)
    |> assign(:timezones, timezones)
    |> push_chart_events(locations, timezones)
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

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
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

        <%!-- Visitor Map --%>
        <div class="bg-white rounded-lg shadow p-5 mb-6">
          <h3 class="text-sm font-medium text-gray-500 mb-4">Visitor Locations</h3>
          <div id="fullpage-map-hook" phx-hook="BubbleMap">
            <div style="height: 450px; position: relative;">
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
                  {loc["visitors"]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
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

  defp to_num(n) when is_integer(n), do: n

  defp to_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_num(_), do: 0

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
