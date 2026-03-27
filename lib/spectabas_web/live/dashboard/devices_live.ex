defmodule SpectabasWeb.Dashboard.DevicesLive do
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
       |> assign(:page_title, "Devices - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> assign(:tab, "device_type")
       |> load_devices()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_devices()}
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:tab, tab)
     |> load_devices()}
  end

  defp load_devices(socket) do
    %{site: site, user: user, date_range: range, tab: tab} = socket.assigns
    period = range_to_atom(range)

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

    assign(socket, :devices, devices)
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
          :for={{id, label} <- [{"device_type", "Device Type"}, {"browser", "Browser"}, {"os", "OS"}]}
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

      <div class="bg-white rounded-lg shadow overflow-hidden">
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
                Pageviews
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :if={@devices == []}>
              <td colspan="3" class="px-6 py-8 text-center text-gray-500">
                No data for this period.
              </td>
            </tr>
            <tr :for={device <- @devices} class="hover:bg-gray-50">
              <td class="px-6 py-4 text-sm text-gray-900">
                {Map.get(device, @tab, "Unknown")}
              </td>
              <td class="px-6 py-4 text-sm text-gray-900 text-right">
                {Map.get(device, "unique_visitors", 0)}
              </td>
              <td class="px-6 py-4 text-sm text-gray-900 text-right">
                {Map.get(device, "pageviews", 0)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
