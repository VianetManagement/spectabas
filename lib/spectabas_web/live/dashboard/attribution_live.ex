defmodule SpectabasWeb.Dashboard.AttributionLive do
  use SpectabasWeb, :live_view

  @moduledoc "Channel attribution dashboard — first-touch and last-touch attribution models."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Attribution - #{site.name}")
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

    channels =
      case Analytics.attribution(site, user, range_to_period(range)) do
        {:ok, rows} -> rows
        _ -> []
      end

    assign(socket, :channels, channels)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Channel Attribution"
      page_description="First-touch vs last-touch attribution by traffic channel."
      active="attribution"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Channel Attribution</h1>
            <p class="text-sm text-gray-500 mt-1">First touch vs last touch attribution by channel</p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7 days"}, {"30d", "30 days"}, {"90d", "90 days"}]}
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
                  Channel
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  First Touch
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Last Touch
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200">
              <tr :if={@channels == []}>
                <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                  No attribution data yet.
                </td>
              </tr>
              <tr :for={ch <- @channels} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-medium text-gray-900">{ch["channel"]}</td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(ch["visitors"]))}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {ch["first_touch"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {ch["last_touch"]}
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
