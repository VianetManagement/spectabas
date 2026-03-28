defmodule SpectabasWeb.Dashboard.PagesLive do
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
       |> assign(:page_title, "Pages - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> assign(:sort_by, "pageviews")
       |> assign(:sort_dir, "desc")
       |> load_pages()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_pages()}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_by == field do
        if socket.assigns.sort_dir == "asc", do: "desc", else: "asc"
      else
        "desc"
      end

    {:noreply,
     socket
     |> assign(:sort_by, field)
     |> assign(:sort_dir, dir)
     |> load_pages()}
  end

  defp load_pages(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns

    pages =
      case Analytics.top_pages(site, user, range_to_atom(range)) do
        {:ok, pages} -> pages
        _ -> []
      end

    assign(socket, :pages, pages)
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
      page_title="Pages"
      page_description="Top pages ranked by pageviews and unique visitors."
      active="pages"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Top Pages</h1>
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

        <div class="bg-white rounded-lg shadow overflow-hidden">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Page
                </th>
                <.sort_header
                  field="pageviews"
                  label="Pageviews"
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                />
                <.sort_header
                  field="unique_visitors"
                  label="Visitors"
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                />
                <.sort_header
                  field="avg_duration"
                  label="Avg Duration"
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                />
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@pages == []}>
                <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                  No data for this period.
                </td>
              </tr>
              <tr :for={page <- @pages} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm truncate max-w-md">
                  <.link
                    navigate={
                      ~p"/dashboard/sites/#{@site.id}/transitions?page=#{Map.get(page, "url_path", "/")}"
                    }
                    class="text-indigo-600 hover:text-indigo-800 font-mono"
                    title="View page transitions"
                  >
                    {Map.get(page, "url_path", "/")}
                  </.link>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {Map.get(page, "pageviews", 0)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {Map.get(page, "unique_visitors", 0)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {format_duration(Map.get(page, "avg_duration", 0))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp sort_header(assigns) do
    ~H"""
    <th
      class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
      phx-click="sort"
      phx-value-field={@field}
    >
      {@label}
      <span :if={@sort_by == @field}>
        {if @sort_dir == "asc", do: raw("&uarr;"), else: raw("&darr;")}
      </span>
    </th>
    """
  end

  defp format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(_), do: "0m 0s"
end
