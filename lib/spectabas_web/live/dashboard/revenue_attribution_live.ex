defmodule SpectabasWeb.Dashboard.RevenueAttributionLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

  @utm_tabs [
    {"source", "Source"},
    {"medium", "Medium"},
    {"campaign", "Campaign"},
    {"term", "Term"},
    {"content", "Content"}
  ]

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
       |> assign(:touch, "first")
       |> assign(:utm_tabs, @utm_tabs)
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

  def handle_event("change_touch", %{"touch" => touch}, socket) do
    {:noreply, socket |> assign(:touch, touch) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, group_by: group, touch: touch} = socket.assigns
    period = range_to_period(range)

    rows =
      case Analytics.revenue_by_source(site, user, period, group_by: group, touch: touch) do
        {:ok, data} -> data
        _ -> []
      end

    channels =
      case Analytics.revenue_by_channel(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    # Compute totals for summary
    total_revenue =
      Enum.reduce(channels, 0, fn c, acc -> acc + parse_float(c["total_revenue"]) end)

    total_orders =
      Enum.reduce(channels, 0, fn c, acc -> acc + to_num(c["orders"]) end)

    total_visitors =
      Enum.reduce(channels, 0, fn c, acc -> acc + to_num(c["visitors"]) end)

    socket
    |> assign(:rows, rows)
    |> assign(:channels, channels)
    |> assign(:total_revenue, total_revenue)
    |> assign(:total_orders, total_orders)
    |> assign(:total_visitors, total_visitors)
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
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Revenue Attribution</h1>
          <div class="flex gap-2">
            <%!-- First/Last Touch Toggle --%>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={{id, label} <- [{"first", "First Touch"}, {"last", "Last Touch"}]}
                phx-click="change_touch"
                phx-value-touch={id}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
                  if(@touch == id,
                    do: "bg-white shadow text-gray-900",
                    else: "text-gray-600 hover:text-gray-900"
                  )
                ]}
              >
                {label}
              </button>
            </nav>
            <%!-- Date Range --%>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={r <- [{"7d", "7d"}, {"30d", "30d"}, {"90d", "90d"}]}
                phx-click="change_range"
                phx-value-range={elem(r, 0)}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
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

        <%!-- Channel Summary Cards --%>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mb-6">
          <div :for={ch <- @channels} class="bg-white rounded-lg shadow p-3">
            <dt class="text-[10px] font-medium text-gray-500 uppercase truncate">
              {ch["channel"]}
            </dt>
            <dd class="mt-0.5 text-lg font-bold text-gray-900">
              {@site.currency} {format_money(ch["total_revenue"])}
            </dd>
            <dd class="text-xs text-gray-500">
              {to_num(ch["orders"])} orders &middot; {ch["conversion_rate"]}%
            </dd>
          </div>
        </div>

        <div :if={@total_revenue > 0} class="bg-indigo-50 rounded-lg p-3 mb-6 flex gap-6 text-sm">
          <span class="font-medium text-indigo-900">
            Total: {@site.currency} {format_money(@total_revenue)}
          </span>
          <span class="text-indigo-700">{format_number(@total_orders)} orders</span>
          <span class="text-indigo-700">{format_number(@total_visitors)} visitors</span>
          <span class="text-indigo-700">
            {if @touch == "first", do: "First-touch", else: "Last-touch"} attribution
          </span>
        </div>

        <%!-- UTM Dimension Tabs --%>
        <nav class="flex gap-1 bg-gray-100 rounded-lg p-1 mb-6 w-fit">
          <button
            :for={{id, label} <- @utm_tabs}
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

        <%!-- Source Table --%>
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
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Rev Share
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@rows == []}>
                <td colspan="7" class="px-6 py-8 text-center text-gray-500">
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
                <td class="px-6 py-4 text-right">
                  <div class="flex items-center justify-end gap-2">
                    <div class="w-16 bg-gray-200 rounded-full h-1.5">
                      <div
                        class="bg-indigo-500 h-1.5 rounded-full"
                        style={"width: #{rev_share_pct(row["total_revenue"], @total_revenue)}%"}
                      >
                      </div>
                    </div>
                    <span class="text-xs text-gray-500 tabular-nums w-10 text-right">
                      {rev_share_pct(row["total_revenue"], @total_revenue)}%
                    </span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <p class="text-xs text-gray-500 mt-3">
          <strong>{if @touch == "first", do: "First-touch", else: "Last-touch"}</strong>
          attribution: revenue is credited to the {if @touch == "first",
            do: "first",
            else: "most recent"} traffic source the customer came from before purchasing.
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

  defp rev_share_pct(revenue, total) when total > 0 do
    r = parse_float(revenue)
    Float.round(r / total * 100, 1)
  end

  defp rev_share_pct(_, _), do: 0.0
end
