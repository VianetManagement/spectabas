defmodule SpectabasWeb.Dashboard.RevenueAttributionLive do
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
       |> assign(:page_title, "Revenue Attribution - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "30d")
       |> assign(:group_by, "source")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  def handle_event("change_group", %{"group" => group}, socket) do
    {:noreply, socket |> assign(:group_by, group) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, group_by: group} = socket.assigns
    period = range_to_period(range)

    rows =
      case Analytics.revenue_by_source(site, user, period, group) do
        {:ok, data} -> data
        _ -> []
      end

    socket |> assign(:rows, rows)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Revenue Attribution"
      page_description="Which traffic sources generate paying customers."
      active="revenue-attribution"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-2xl font-bold text-gray-900">Revenue Attribution</h1>
          <div class="flex gap-3">
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={
                  {id, label} <- [
                    {"source", "Source"},
                    {"campaign", "Campaign"},
                    {"medium", "Medium"}
                  ]
                }
                phx-click="change_group"
                phx-value-group={id}
                class={[
                  "px-3 py-1.5 text-sm font-medium rounded-md",
                  if(@group_by == id,
                    do: "bg-white shadow text-gray-900",
                    else: "text-gray-600 hover:text-gray-900"
                  )
                ]}
              >
                {label}
              </button>
            </nav>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={r <- [{"7d", "7d"}, {"30d", "30d"}]}
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
        </div>

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  {String.capitalize(@group_by)}
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Orders
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Revenue
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  AOV
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Conv Rate
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@rows == []}>
                <td colspan="6" class="px-6 py-8 text-center text-gray-500">
                  No revenue data for this period.
                </td>
              </tr>
              <tr :for={row <- @rows} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-medium text-gray-900">
                  {row["source"] || "Direct"}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(row["visitors"]))}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(row["orders"]))}
                </td>
                <td class="px-6 py-4 text-sm font-medium text-green-600 text-right tabular-nums">
                  {@site.currency} {format_money(row["total_revenue"])}
                </td>
                <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                  {@site.currency} {format_money(row["avg_order_value"])}
                </td>
                <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                  {row["conversion_rate"]}%
                </td>
              </tr>
            </tbody>
          </table>
        </div>
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
end
