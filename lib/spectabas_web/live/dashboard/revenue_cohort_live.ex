defmodule SpectabasWeb.Dashboard.RevenueCohortLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
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
       |> assign(:page_title, "Revenue Cohorts - #{site.name}")
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
    period = range_to_period(range)

    rows =
      case Analytics.cohort_revenue(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    # Group by cohort_week for the grid
    cohorts =
      rows
      |> Enum.group_by(& &1["cohort_week"])
      |> Enum.sort_by(fn {week, _} -> week end)
      |> Enum.map(fn {week, week_rows} ->
        weeks =
          Enum.sort_by(week_rows, &to_num(&1["week_number"]))
          |> Enum.map(fn r ->
            %{
              week: to_num(r["week_number"]),
              customers: to_num(r["customers"]),
              revenue: format_money(r["revenue"]),
              rpc: format_money(r["revenue_per_customer"])
            }
          end)

        total_revenue =
          Enum.reduce(week_rows, 0, fn r, acc ->
            acc + parse_float(r["revenue"])
          end)

        %{cohort_week: week, weeks: weeks, total_revenue: format_money(total_revenue)}
      end)

    max_week =
      rows
      |> Enum.map(&to_num(&1["week_number"]))
      |> Enum.max(fn -> 0 end)
      |> min(12)

    socket
    |> assign(:cohorts, cohorts)
    |> assign(:max_week, max_week)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Revenue Cohorts"
      page_description="Customer lifetime value by signup cohort."
      active="revenue-cohorts"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-2xl font-bold text-gray-900">Revenue Cohorts</h1>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"30d", "30d"}, {"90d", "90d"}]}
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

        <div :if={@cohorts == []} class="bg-white rounded-lg shadow p-8 text-center text-gray-500">
          No cohort data yet. Revenue cohorts appear after customers make purchases.
        </div>

        <div :if={@cohorts != []} class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase sticky left-0 bg-gray-50">
                  Cohort
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Total
                </th>
                <th
                  :for={w <- 0..@max_week}
                  class="px-3 py-3 text-center text-xs font-medium text-gray-500 uppercase"
                >
                  Wk {w}
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :for={cohort <- @cohorts} class="hover:bg-gray-50">
                <td class="px-4 py-3 text-sm font-medium text-gray-900 sticky left-0 bg-white whitespace-nowrap">
                  {cohort.cohort_week}
                </td>
                <td class="px-4 py-3 text-sm font-medium text-green-600 text-right tabular-nums">
                  {@site.currency} {cohort.total_revenue}
                </td>
                <td :for={w <- 0..@max_week} class="px-3 py-3 text-center text-xs tabular-nums">
                  <% week_data = Enum.find(cohort.weeks, &(&1.week == w)) %>
                  <span
                    :if={week_data}
                    class="text-gray-900"
                    title={"#{week_data.customers} customers"}
                  >
                    {week_data.rpc}
                  </span>
                  <span :if={!week_data} class="text-gray-300">-</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@cohorts != []} class="text-xs text-gray-500 mt-2">
          Each cell shows revenue per customer. Hover for customer count.
        </p>
      </div>
    </.dashboard_layout>
    """
  end

  defp format_money(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 2)
      :error -> "0.00"
    end
  end

  defp format_money(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp format_money(_), do: "0.00"

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(n) when is_number(n), do: n / 1
  defp parse_float(_), do: 0.0
end
