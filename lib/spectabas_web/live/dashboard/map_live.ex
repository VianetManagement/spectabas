defmodule SpectabasWeb.Dashboard.MapLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}

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
       |> assign(:page_title, "Visitor Map - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_data()}
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
  end

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <div>
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            &larr; Back to {@site.name}
          </.link>
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
        <.visitor_map locations={@locations} />
      </div>

      <%!-- Timezone Distribution --%>
      <div class="bg-white rounded-lg shadow p-5 mb-6">
        <h3 class="text-sm font-medium text-gray-500 mb-4">Timezone Distribution</h3>
        <.timezone_chart timezones={@timezones} />
      </div>

      <%!-- Location Table --%>
      <div class="bg-white rounded-lg shadow overflow-hidden">
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
              <td colspan="2" class="px-6 py-8 text-center text-gray-500">No location data yet.</td>
            </tr>
            <tr :for={loc <- Enum.take(@locations, 20)} class="hover:bg-gray-50">
              <td class="px-6 py-3 text-sm text-gray-900">
                {location_name(loc)}
              </td>
              <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                {loc["visitors"]}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # -- Map Component (Equirectangular projection) --

  defp visitor_map(assigns) do
    locations = assigns.locations

    max_visitors =
      locations |> Enum.map(&to_num(&1["visitors"])) |> Enum.max(fn -> 1 end) |> max(1)

    # Map dimensions
    w = 900
    h = 450

    points =
      Enum.map(locations, fn loc ->
        lat = to_float(loc["ip_lat"])
        lon = to_float(loc["ip_lon"])
        visitors = to_num(loc["visitors"])

        # Equirectangular projection
        x = (lon + 180) / 360 * w
        y = (90 - lat) / 180 * h

        # Scale dot size: 3-12px based on visitor count
        r = 3 + 9 * :math.sqrt(visitors / max_visitors)
        opacity = 0.3 + 0.5 * (visitors / max_visitors)

        %{
          x: x,
          y: y,
          r: Float.round(r, 1),
          opacity: Float.round(opacity, 2),
          title: location_name(loc)
        }
      end)

    assigns = Map.put(assigns, :points, points) |> Map.put(:w, w) |> Map.put(:h, h)

    ~H"""
    <div :if={@locations == []} class="h-48 flex items-center justify-center text-sm text-gray-400">
      No location data yet
    </div>
    <svg
      :if={@locations != []}
      viewBox={"0 0 #{@w} #{@h}"}
      class="w-full rounded-lg"
      style="background: #f0f4f8;"
    >
      <%!-- Grid lines for reference --%>
      <line
        :for={lon <- [-120, -60, 0, 60, 120]}
        x1={(lon + 180) / 360 * @w}
        y1="0"
        x2={(lon + 180) / 360 * @w}
        y2={@h}
        stroke="#dde3ea"
        stroke-width="0.5"
      />
      <line
        :for={lat <- [-60, -30, 0, 30, 60]}
        x1="0"
        y1={(90 - lat) / 180 * @h}
        x2={@w}
        y2={(90 - lat) / 180 * @h}
        stroke="#dde3ea"
        stroke-width="0.5"
      />
      <%!-- Equator --%>
      <line x1="0" y1={@h / 2} x2={@w} y2={@h / 2} stroke="#cdd4dc" stroke-width="1" />
      <%!-- Visitor dots --%>
      <circle
        :for={pt <- @points}
        cx={pt.x}
        cy={pt.y}
        r={pt.r}
        fill="#6366f1"
        fill-opacity={pt.opacity}
        stroke="#4f46e5"
        stroke-width="0.5"
        stroke-opacity={pt.opacity}
      >
        <title>{pt.title}</title>
      </circle>
    </svg>
    """
  end

  # -- Timezone Chart Component --

  defp timezone_chart(assigns) do
    timezones = assigns.timezones
    max_v = timezones |> Enum.map(&to_num(&1["visitors"])) |> Enum.max(fn -> 1 end) |> max(1)
    count = length(timezones)

    assigns = Map.put(assigns, :max_v, max_v) |> Map.put(:count, count)

    ~H"""
    <div :if={@timezones == []} class="h-32 flex items-center justify-center text-sm text-gray-400">
      No timezone data yet
    </div>
    <div :if={@timezones != []} class="space-y-2">
      <div :for={tz <- Enum.take(@timezones, 15)} class="flex items-center gap-3">
        <span class="text-xs text-gray-600 w-40 truncate text-right" title={tz["timezone"]}>
          {short_tz(tz["timezone"])}
        </span>
        <div class="flex-1 bg-gray-100 rounded-full h-5 overflow-hidden">
          <div
            class="bg-indigo-500 h-5 rounded-full flex items-center justify-end pr-2"
            style={"width: #{max(to_num(tz["visitors"]) / @max_v * 100, 2)}%"}
          >
            <span class="text-xs text-white font-medium">{tz["visitors"]}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp location_name(loc) do
    city = loc["ip_city"] || ""
    region = loc["ip_region_name"] || ""
    country = loc["ip_country"] || ""

    parts = [city, region, country] |> Enum.reject(&(&1 == ""))

    case parts do
      [] -> "Unknown"
      _ -> Enum.join(parts, ", ")
    end
  end

  defp short_tz(tz) when is_binary(tz) do
    # "America/New_York" -> "New York"
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
