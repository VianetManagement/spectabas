defmodule SpectabasWeb.Dashboard.TransitionsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      page = params["page"] || "/"

      {:ok,
       socket
       |> assign(:page_title, "Page Transitions - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> assign(:current_page, page)
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:current_page, page) |> load_data()}
  end

  def handle_event("navigate_page", %{"path" => path}, socket) do
    {:noreply, socket |> assign(:current_page, path) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, current_page: page} = socket.assigns

    transitions =
      case Analytics.page_transitions(site, user, page, range_to_atom(range)) do
        {:ok, data} -> data
        _ -> %{previous: [], next: [], totals: %{}}
      end

    assign(socket, :transitions, transitions)
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
      page_title="Page Transitions"
      page_description="See where visitors came from and went to for any page."
      active="transitions"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Page Transitions</h1>
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

        <%!-- Page selector --%>
        <div class="bg-white rounded-lg shadow p-5 mb-6">
          <form phx-submit="change_page" class="flex items-end gap-3">
            <div class="flex-1">
              <label class="block text-xs font-medium text-gray-500 mb-1">Page path</label>
              <input
                type="text"
                name="page"
                value={@current_page}
                class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500 font-mono"
                placeholder="/pricing"
              />
            </div>
            <button
              type="submit"
              class="px-4 py-2 text-sm font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700"
            >
              Analyze
            </button>
          </form>
        </div>

        <%!-- Current page stats --%>
        <div class="bg-indigo-50 rounded-lg p-5 mb-6 text-center">
          <p class="text-sm text-indigo-600 font-medium">Current Page</p>
          <p class="text-2xl font-bold text-indigo-900 font-mono mt-1">{@current_page}</p>
          <div class="flex justify-center gap-8 mt-3 text-sm text-indigo-700">
            <span>{@transitions.totals["total_views"] || 0} views</span>
            <span>{@transitions.totals["unique_visitors"] || 0} visitors</span>
            <span>{@transitions.totals["sessions"] || 0} sessions</span>
          </div>
        </div>

        <%!-- Transition flow --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <%!-- Previous pages --%>
          <div class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="font-semibold text-gray-900">Came from</h3>
              <p class="text-xs text-gray-400">Pages visitors viewed before this one</p>
            </div>
            <div class="divide-y divide-gray-50">
              <div
                :if={@transitions.previous == []}
                class="px-5 py-8 text-center text-sm text-gray-400"
              >
                No previous pages (entry point)
              </div>
              <div
                :for={row <- @transitions.previous}
                class="px-5 py-3 flex items-center justify-between hover:bg-gray-50 cursor-pointer"
                phx-click="navigate_page"
                phx-value-path={row["prev_page"]}
              >
                <span class="text-sm text-indigo-600 font-mono truncate mr-4">
                  {row["prev_page"]}
                </span>
                <span class="text-sm font-medium text-gray-600 tabular-nums">
                  {row["transitions"]}
                </span>
              </div>
            </div>
          </div>

          <%!-- Next pages --%>
          <div class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="font-semibold text-gray-900">Went to</h3>
              <p class="text-xs text-gray-400">Pages visitors viewed after this one</p>
            </div>
            <div class="divide-y divide-gray-50">
              <div :if={@transitions.next == []} class="px-5 py-8 text-center text-sm text-gray-400">
                No next pages (exit point)
              </div>
              <div
                :for={row <- @transitions.next}
                class="px-5 py-3 flex items-center justify-between hover:bg-gray-50 cursor-pointer"
                phx-click="navigate_page"
                phx-value-path={row["next_page"]}
              >
                <span class="text-sm text-indigo-600 font-mono truncate mr-4">
                  {row["next_page"]}
                </span>
                <span class="text-sm font-medium text-gray-600 tabular-nums">
                  {row["transitions"]}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
