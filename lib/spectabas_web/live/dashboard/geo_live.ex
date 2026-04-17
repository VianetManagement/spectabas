defmodule SpectabasWeb.Dashboard.GeoLive do
  use SpectabasWeb, :live_view

  @moduledoc "Geography dashboard with country/region/city drill-down."

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
        |> assign(:page_title, "Geography - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:drill_country, nil)
        |> assign(:drill_region, nil)
        |> assign(:geo_data, [])
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
     |> assign(:drill_country, nil)
     |> assign(:drill_region, nil)
     |> assign(:loading, true)}
  end

  def handle_event("drill_country", %{"country" => country}, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:drill_country, country)
     |> assign(:drill_region, nil)
     |> assign(:loading, true)}
  end

  def handle_event("drill_region", %{"region" => region}, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:drill_region, region)
     |> assign(:loading, true)}
  end

  def handle_event("reset_drill", _params, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:drill_country, nil)
     |> assign(:drill_region, nil)
     |> assign(:loading, true)}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_geo() |> assign(:loading, false)}
  end

  defp load_geo(socket) do
    %{site: site, user: user, date_range: range, drill_country: dc, drill_region: dr} =
      socket.assigns

    period = range_to_period(range)

    data =
      cond do
        # Drilled to region: show cities
        dc && dr ->
          case Analytics.top_countries(site, user, period) do
            {:ok, rows} ->
              rows
              |> Enum.filter(&(&1["ip_country"] == dc && &1["ip_region_name"] == dr))

            _ ->
              []
          end

        # Drilled to country: show regions
        dc ->
          case Analytics.top_regions(site, user, period) do
            {:ok, rows} ->
              Enum.filter(rows, &(&1["ip_country"] == dc))

            _ ->
              []
          end

        # Top level: show countries (deduplicated)
        true ->
          case Analytics.top_countries_summary(site, user, period) do
            {:ok, rows} -> rows
            _ -> []
          end
      end

    assign(socket, :geo_data, data)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Geography"
      page_description="Visitor locations by country, region, and city. Click a country to drill down."
      active="geo"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Geography</h1>
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

        <div :if={@drill_country || @drill_region} class="mb-4 flex items-center gap-2 text-sm">
          <button phx-click="reset_drill" class="text-indigo-600 hover:text-indigo-800">
            All Countries
          </button>
          <span :if={@drill_country} class="text-gray-500">/</span>
          <span :if={@drill_country && !@drill_region} class="font-medium text-gray-900">
            {@drill_country}
          </span>
          <button
            :if={@drill_country && @drill_region}
            phx-click="drill_country"
            phx-value-country={@drill_country}
            class="text-indigo-600 hover:text-indigo-800"
          >
            {@drill_country}
          </button>
          <span :if={@drill_region} class="text-gray-500">/</span>
          <span :if={@drill_region} class="font-medium text-gray-900">{@drill_region}</span>
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
              <span>Loading...</span>
            </div>
          </div>
        <% else %>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    {drill_label(@drill_country, @drill_region)}
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Visitors
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Pageviews
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :if={@geo_data == []}>
                  <td colspan="3" class="px-6 py-8 text-center text-gray-500">
                    No data for this period.
                  </td>
                </tr>
                <tr :for={row <- @geo_data} class="hover:bg-gray-50">
                  <td class="px-6 py-4 text-sm text-gray-900">
                    <button
                      :if={!@drill_country}
                      phx-click="drill_country"
                      phx-value-country={Map.get(row, "ip_country", "")}
                      class="text-indigo-600 hover:text-indigo-800"
                    >
                      {country_display(row)}
                    </button>
                    <button
                      :if={@drill_country && !@drill_region}
                      phx-click="drill_region"
                      phx-value-region={Map.get(row, "ip_region_name", "")}
                      class="text-indigo-600 hover:text-indigo-800"
                    >
                      {Map.get(row, "ip_region_name", "Unknown")}
                    </button>
                    <span :if={@drill_region}>
                      {Map.get(row, "ip_city", "Unknown")}
                    </span>
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right">
                    {format_number(to_num(Map.get(row, "unique_visitors", 0)))}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right">
                    {format_number(to_num(Map.get(row, "pageviews", 0)))}
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

  defp drill_label(nil, _), do: "Country"
  defp drill_label(_, nil), do: "Region"
  defp drill_label(_, _), do: "City"

  defp country_display(row) do
    name = row["ip_country_name"] || ""
    code = row["ip_country"] || ""

    cond do
      name != "" && code != "" -> "#{name} (#{code})"
      name != "" -> name
      code != "" -> code
      true -> "Unknown"
    end
  end
end
