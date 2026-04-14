defmodule SpectabasWeb.Dashboard.EntryExitLive do
  use SpectabasWeb, :live_view

  @moduledoc "Entry and exit pages — where visitors land and leave."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

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
      socket =
        socket
        |> assign(:page_title, "Entry & Exit Pages - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:tab, "entry")
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:tab, tab) |> assign(:loading, true)}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, tab: tab} = socket.assigns
    period = range_to_period(range)

    data =
      case tab do
        "entry" ->
          case Analytics.entry_pages(site, user, period) do
            {:ok, rows} -> rows
            _ -> []
          end

        "exit" ->
          case Analytics.exit_pages(site, user, period) do
            {:ok, rows} -> rows
            _ -> []
          end

        _ ->
          []
      end

    assign(socket, :data, data)
  end

  defp count_key("entry"), do: "entries"
  defp count_key(_), do: "exits"

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Entry & Exit Pages"
      page_description="Where visitors land and where they leave your site."
      active="entry-exit"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Entry & Exit Pages</h1>
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
          <div class="flex gap-1 bg-gray-100 rounded-lg p-1 mb-6 w-fit">
            <button
              :for={{id, label} <- [{"entry", "Entry Pages"}, {"exit", "Exit Pages"}]}
              phx-click="change_tab"
              phx-value-tab={id}
              class={[
                "px-4 py-2 text-sm font-medium rounded-md",
                if(@tab == id,
                  do: "bg-white shadow text-gray-900",
                  else: "text-gray-600 hover:text-gray-900"
                )
              ]}
            >
              {label}
            </button>
          </div>

          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Page
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Visitors
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    {if @tab == "entry", do: "Entries", else: "Exits"}
                  </th>
                  <th
                    :if={@tab == "entry"}
                    class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider"
                  >
                    Bounce Rate
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Avg Duration
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :if={@data == []}>
                  <td
                    colspan={if @tab == "entry", do: "5", else: "4"}
                    class="px-6 py-8 text-center text-gray-500"
                  >
                    No data for this period.
                  </td>
                </tr>
                <tr :for={row <- @data} class="hover:bg-gray-50">
                  <td class="px-6 py-4 text-sm text-gray-900 font-mono">
                    {row["url_path"]}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row["unique_visitors"]))}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row[count_key(@tab)]))}
                  </td>
                  <td
                    :if={@tab == "entry"}
                    class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums"
                  >
                    {row["bounce_rate"]}%
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                    {format_duration(to_num(row["avg_duration"]))}
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
end
