defmodule SpectabasWeb.Dashboard.VisitorsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Visitors}
  import SpectabasWeb.Dashboard.SidebarComponent

  @per_page 50

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
       |> assign(:page_title, "Visitors - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:search, "")
       |> assign(:page, 1)
       |> load_visitors()}
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search, search)
     |> assign(:page, 1)
     |> load_visitors()}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:page, socket.assigns.page + 1)
     |> load_visitors()}
  end

  def handle_event("prev_page", _params, socket) do
    page = max(1, socket.assigns.page - 1)

    {:noreply,
     socket
     |> assign(:page, page)
     |> load_visitors()}
  end

  defp load_visitors(socket) do
    %{site: site, search: search, page: page} = socket.assigns

    {visitors, total} =
      Visitors.list_visitors(site.id,
        search: search,
        limit: @per_page,
        offset: (page - 1) * @per_page
      )

    socket
    |> assign(:visitors, visitors)
    |> assign(:total, total)
    |> assign(:total_pages, max(1, ceil(total / @per_page)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Visitors"
      page_description="Browse and search visitor records."
      active="visitor-log"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Visitors</h1>
          </div>
          <div class="text-sm text-gray-500">
            {@total} total visitors
          </div>
        </div>

        <div class="mb-6">
          <form phx-change="search" phx-submit="search">
            <input
              type="text"
              name="search"
              value={@search}
              placeholder="Search by email, user ID, or cookie ID..."
              class="block w-full md:w-96 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              phx-debounce="300"
            />
          </form>
        </div>

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Visitor
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Email
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  First Seen
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Last Seen
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  GDPR
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@visitors == []}>
                <td colspan="5" class="px-6 py-8 text-center text-gray-500">No visitors found.</td>
              </tr>
              <tr :for={visitor <- @visitors} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{visitor.id}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {String.slice(to_string(visitor.id), 0..7)}...
                  </.link>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900">
                  {visitor.email || "-"}
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  {format_datetime(visitor.first_seen_at)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  {format_datetime(visitor.last_seen_at)}
                </td>
                <td class="px-6 py-4">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    if(visitor.gdpr_mode == "on",
                      do: "bg-green-100 text-green-800",
                      else: "bg-gray-100 text-gray-800"
                    )
                  ]}>
                    {visitor.gdpr_mode}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div :if={@total_pages > 1} class="flex items-center justify-between mt-4">
          <button
            :if={@page > 1}
            phx-click="prev_page"
            class="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
          >
            Previous
          </button>
          <span class="text-sm text-gray-500">
            Page {@page} of {@total_pages}
          </span>
          <button
            :if={@page < @total_pages}
            phx-click="next_page"
            class="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
          >
            Next
          </button>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
