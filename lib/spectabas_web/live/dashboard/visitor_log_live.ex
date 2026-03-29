defmodule SpectabasWeb.Dashboard.VisitorLogLive do
  use SpectabasWeb, :live_view

  @moduledoc "Visitor log — browsable session list with filtering."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      # Accept filter from URL (e.g., from network page ASN click)
      segment =
        case {params["filter_field"], params["filter_value"]} do
          {f, v} when is_binary(f) and is_binary(v) and f != "" and v != "" ->
            [%{"field" => f, "op" => "is", "value" => v}]

          _ ->
            []
        end

      {:ok,
       socket
       |> assign(:page_title, "Visitor Log - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> assign(:page, 1)
       |> assign(:segment, segment)
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> assign(:page, 1) |> load_data()}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_data()}
  end

  def handle_event("prev_page", _params, socket) do
    page = max(socket.assigns.page - 1, 1)
    {:noreply, socket |> assign(:page, page) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, page: page, segment: segment} = socket.assigns

    visitors =
      case Analytics.visitor_log(site, user, range_to_period(range),
             page: page,
             per_page: 30,
             segment: segment
           ) do
        {:ok, rows} -> rows
        _ -> []
      end

    assign(socket, :visitors, visitors)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Visitor Log"
      page_description="Browse individual visitor sessions with location, device, and traffic source."
      active="visitor-log"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Visitor Log</h1>
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

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Intent
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Pages</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Duration
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Location
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                  Device
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Source
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                  Entry
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200">
              <tr :if={@visitors == []}>
                <td colspan="8" class="px-4 py-8 text-center text-gray-500">
                  No visitors for this period.
                </td>
              </tr>
              <tr :for={v <- @visitors} class="hover:bg-gray-50">
                <td class="px-4 py-3 text-sm">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {String.slice(v["visitor_id"] || "", 0, 8)}...
                  </.link>
                </td>
                <td class="px-4 py-3">
                  <.link
                    :if={v["intent"] && v["intent"] != ""}
                    navigate={
                      ~p"/dashboard/sites/#{@site.id}/visitor-log?filter_field=visitor_intent&filter_value=#{v["intent"]}"
                    }
                    class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      intent_pill(v["intent"])
                    ]}
                  >
                    {v["intent"]}
                  </.link>
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 tabular-nums">{v["pageviews"]}</td>
                <td class="px-4 py-3 text-sm text-gray-500 tabular-nums">
                  {format_duration(to_int(v["duration"]))}
                </td>
                <td class="px-4 py-3 text-sm">
                  <.link
                    :if={v["country"] && v["country"] != ""}
                    navigate={~p"/dashboard/sites/#{@site.id}/geo"}
                    class="text-indigo-600 hover:text-indigo-800"
                  >
                    {[v["city"], v["region"], v["country"]]
                    |> Enum.reject(&(&1 == "" || is_nil(&1)))
                    |> Enum.join(", ")}
                  </.link>
                  <span :if={!v["country"] || v["country"] == ""} class="text-gray-500">-</span>
                </td>
                <td class="px-4 py-3 text-sm text-gray-500 hidden md:table-cell">
                  {[v["browser"], v["os"]]
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(" / ")}
                </td>
                <td class="px-4 py-3 text-sm truncate max-w-[120px]">
                  <.link
                    :if={v["referrer"] && v["referrer"] != ""}
                    navigate={
                      ~p"/dashboard/sites/#{@site.id}/visitor-log?filter_field=referrer_domain&filter_value=#{v["referrer"]}"
                    }
                    class="text-indigo-600 hover:text-indigo-800"
                  >
                    {v["referrer"]}
                  </.link>
                  <span :if={!v["referrer"] || v["referrer"] == ""} class="text-gray-500">
                    Direct
                  </span>
                </td>
                <td class="px-4 py-3 text-sm truncate max-w-[150px] hidden md:table-cell">
                  <.link
                    :if={v["entry_page"] && v["entry_page"] != ""}
                    navigate={~p"/dashboard/sites/#{@site.id}/transitions?page=#{v["entry_page"]}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono"
                  >
                    {v["entry_page"]}
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="flex items-center justify-between mt-4">
          <button
            :if={@page > 1}
            phx-click="prev_page"
            class="px-3 py-1.5 text-sm bg-white border border-gray-300 rounded-md hover:bg-gray-50"
          >
            &larr; Previous
          </button>
          <span class="text-sm text-gray-500">Page {@page}</span>
          <button
            :if={length(@visitors) == 30}
            phx-click="next_page"
            class="px-3 py-1.5 text-sm bg-white border border-gray-300 rounded-md hover:bg-gray-50"
          >
            Next &rarr;
          </button>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp intent_pill("buying"), do: "bg-green-100 text-green-800"
  defp intent_pill("researching"), do: "bg-blue-100 text-blue-800"
  defp intent_pill("comparing"), do: "bg-purple-100 text-purple-800"
  defp intent_pill("support"), do: "bg-yellow-100 text-yellow-800"
  defp intent_pill("returning"), do: "bg-indigo-100 text-indigo-800"
  defp intent_pill("browsing"), do: "bg-gray-100 text-gray-700"
  defp intent_pill("bot"), do: "bg-red-100 text-red-800"
  defp intent_pill(_), do: "bg-gray-100 text-gray-700"
end
