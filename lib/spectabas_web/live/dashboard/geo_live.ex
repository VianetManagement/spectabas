defmodule SpectabasWeb.Dashboard.GeoLive do
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
      {:ok,
       socket
       |> assign(:page_title, "Geography - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> assign(:drill_country, nil)
       |> assign(:drill_region, nil)
       |> load_geo()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> assign(:drill_country, nil)
     |> assign(:drill_region, nil)
     |> load_geo()}
  end

  def handle_event("drill_country", %{"country" => country}, socket) do
    {:noreply,
     socket
     |> assign(:drill_country, country)
     |> assign(:drill_region, nil)
     |> load_geo()}
  end

  def handle_event("drill_region", %{"region" => region}, socket) do
    {:noreply,
     socket
     |> assign(:drill_region, region)
     |> load_geo()}
  end

  def handle_event("reset_drill", _params, socket) do
    {:noreply,
     socket
     |> assign(:drill_country, nil)
     |> assign(:drill_region, nil)
     |> load_geo()}
  end

  defp load_geo(socket) do
    %{site: site, user: user, date_range: range, drill_country: dc, drill_region: dr} =
      socket.assigns

    period = range_to_atom(range)

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

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
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
                  {Map.get(row, "unique_visitors", 0)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {Map.get(row, "pageviews", 0)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
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
