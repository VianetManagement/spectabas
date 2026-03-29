defmodule SpectabasWeb.Dashboard.CohortLive do
  use SpectabasWeb, :live_view

  @moduledoc "Weekly cohort retention grid showing returning visitor percentages."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Cohort Retention - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "90d")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns

    raw =
      case Analytics.cohort_retention(site, user, range_to_period(range)) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Build cohort grid: %{cohort_week => %{0 => %{visitors: n, pct: x}, 1 => ...}}
    grid = build_grid(raw)

    socket
    |> assign(:cohort_grid, grid)
    |> assign(:cohort_weeks, grid |> Map.keys() |> Enum.sort())
    |> assign(:max_week, raw |> Enum.map(&to_num(&1["week_number"])) |> Enum.max(fn -> 0 end))
  end

  defp range_to_period("30d"), do: :month

  defp range_to_period("90d"),
    do: %{from: DateTime.add(DateTime.utc_now(), -90, :day), to: DateTime.utc_now()}

  defp range_to_period("180d"),
    do: %{from: DateTime.add(DateTime.utc_now(), -180, :day), to: DateTime.utc_now()}

  defp range_to_period(_),
    do: %{from: DateTime.add(DateTime.utc_now(), -90, :day), to: DateTime.utc_now()}

  defp build_grid(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      week = row["cohort_week"] || ""
      wn = to_num(row["week_number"])
      visitors = to_num(row["visitors"])
      cohort_size = to_num(row["cohort_size"])
      pct = if cohort_size > 0, do: Float.round(visitors / cohort_size * 100, 1), else: 0.0

      week_data = Map.get(acc, week, %{})

      Map.put(
        acc,
        week,
        Map.put(week_data, wn, %{visitors: visitors, pct: pct, cohort_size: cohort_size})
      )
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Cohort Retention"
      page_description="Weekly retention grid showing returning visitor percentages."
      active="cohort"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Cohort Retention</h1>
            <p class="text-sm text-gray-500 mt-1">
              Percentage of visitors returning in subsequent weeks after their first visit
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"30d", "30 days"}, {"90d", "90 days"}, {"180d", "6 months"}]}
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
          <table class="min-w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase sticky left-0 bg-gray-50">
                  Cohort
                </th>
                <th class="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase">
                  Size
                </th>
                <th
                  :for={w <- 0..min(@max_week, 12)}
                  class="px-4 py-3 text-center text-xs font-medium text-gray-500 uppercase"
                >
                  {if w == 0, do: "Week 0", else: "+#{w}w"}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={@cohort_weeks == []}>
                <td colspan={@max_week + 3} class="px-4 py-8 text-center text-gray-500">
                  Not enough data for cohort analysis yet.
                </td>
              </tr>
              <tr :for={week <- @cohort_weeks}>
                <td class="px-4 py-2 text-xs text-gray-700 font-medium whitespace-nowrap sticky left-0 bg-white">
                  {format_week(week)}
                </td>
                <td class="px-4 py-2 text-xs text-gray-500 text-center tabular-nums">
                  {cohort_size(@cohort_grid, week)}
                </td>
                <td
                  :for={w <- 0..min(@max_week, 12)}
                  class="px-4 py-2 text-center"
                >
                  <% cell = get_in(@cohort_grid, [week, w]) %>
                  <span
                    :if={cell}
                    class="inline-block px-2 py-1 rounded text-xs tabular-nums font-medium"
                    style={"background-color: #{retention_color(cell.pct)}; color: #{if cell.pct > 50, do: "white", else: "#374151"}"}
                  >
                    {cell.pct}%
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp format_week(week) when is_binary(week) do
    case String.split(week, "-") do
      [_, m, d] -> "#{m}/#{d}"
      _ -> week
    end
  end

  defp format_week(week), do: to_string(week)

  defp cohort_size(grid, week) do
    case get_in(grid, [week, 0]) do
      %{cohort_size: s} -> s
      _ -> "-"
    end
  end

  defp retention_color(pct) when pct >= 80, do: "rgba(99, 102, 241, 0.9)"
  defp retention_color(pct) when pct >= 60, do: "rgba(99, 102, 241, 0.7)"
  defp retention_color(pct) when pct >= 40, do: "rgba(99, 102, 241, 0.5)"
  defp retention_color(pct) when pct >= 20, do: "rgba(99, 102, 241, 0.3)"
  defp retention_color(pct) when pct > 0, do: "rgba(99, 102, 241, 0.15)"
  defp retention_color(_), do: "transparent"
end
