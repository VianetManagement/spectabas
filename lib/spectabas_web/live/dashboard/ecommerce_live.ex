defmodule SpectabasWeb.Dashboard.EcommerceLive do
  use SpectabasWeb, :live_view

  @moduledoc "Ecommerce dashboard — revenue, orders, AOV, and top products."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

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
       |> assign(:page_title, "Ecommerce - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> load_ecommerce()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_ecommerce()}
  end

  defp load_ecommerce(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    stats =
      case Analytics.ecommerce_stats(site, user, period) do
        {:ok, data} -> data
        _ -> %{"total_orders" => 0, "total_revenue" => 0, "avg_order_value" => 0}
      end

    products =
      case Analytics.ecommerce_top_products(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    orders =
      case Analytics.ecommerce_orders(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    timeseries =
      case Analytics.ecommerce_timeseries(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    by_channel =
      case Analytics.ecommerce_by_channel(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    by_source =
      case Analytics.ecommerce_by_source(site, user, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Enrich orders with visitor emails
    visitor_ids = Enum.map(orders, & &1["visitor_id"]) |> Enum.reject(&(is_nil(&1) or &1 == ""))
    email_map = Spectabas.Visitors.emails_for_visitor_ids(visitor_ids)

    socket
    |> assign(:ecommerce, stats)
    |> assign(:top_products, products)
    |> assign(:orders, orders)
    |> assign(:email_map, email_map)
    |> assign(:timeseries, timeseries)
    |> assign(:by_channel, by_channel)
    |> assign(:by_source, by_source)
    |> push_ecommerce_chart(timeseries)
  end

  defp push_ecommerce_chart(socket, timeseries) do
    if Phoenix.LiveView.connected?(socket) do
      push_event(socket, "ecommerce-chart-data", %{
        labels: Enum.map(timeseries, & &1["day"]),
        revenue: Enum.map(timeseries, &parse_float(&1["revenue"])),
        orders: Enum.map(timeseries, &to_num(&1["orders"]))
      })
    else
      socket
    end
  end

  defp parse_float(nil), do: 0.0
  defp parse_float(n) when is_number(n), do: n / 1

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(_), do: 0.0

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Ecommerce"
      page_description="Revenue, orders, and product analytics."
      active="ecommerce"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Ecommerce</h1>
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

        <div
          :if={!@site.ecommerce_enabled}
          class="bg-yellow-50 border border-yellow-200 rounded-lg p-6 mb-8"
        >
          <p class="text-yellow-800">
            Ecommerce tracking is not enabled for this site. Enable it in <.link
              navigate={~p"/dashboard/sites/#{@site.id}/settings"}
              class="underline"
            >Settings</.link>.
          </p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
          <div class="bg-white rounded-lg shadow p-6">
            <dt class="text-sm font-medium text-gray-500">Total Revenue</dt>
            <dd class="mt-1 text-3xl font-bold text-gray-900">
              {Spectabas.Currency.format(@ecommerce["total_revenue"], @site.currency)}
            </dd>
          </div>
          <div class="bg-white rounded-lg shadow p-6">
            <dt class="text-sm font-medium text-gray-500">Orders</dt>
            <dd class="mt-1 text-3xl font-bold text-gray-900">
              {format_number(to_num(@ecommerce["total_orders"]))}
            </dd>
          </div>
          <div class="bg-white rounded-lg shadow p-6">
            <dt class="text-sm font-medium text-gray-500">Avg Order Value</dt>
            <dd class="mt-1 text-3xl font-bold text-gray-900">
              {Spectabas.Currency.format(@ecommerce["avg_order_value"], @site.currency)}
            </dd>
          </div>
        </div>

        <%!-- Revenue & Orders Chart --%>
        <div
          class="bg-white rounded-lg shadow p-5 mb-8"
          id="ecommerce-chart-hook"
          phx-hook="EcommerceChart"
        >
          <h2 class="text-sm font-medium text-gray-500 mb-3">Revenue & Orders</h2>
          <div class="h-48 sm:h-[260px] relative">
            <canvas></canvas>
          </div>
        </div>

        <%!-- Channel & Source Breakdown --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-6 py-4 border-b border-gray-200">
              <h2 class="text-lg font-semibold text-gray-900">By Channel</h2>
              <p class="text-xs text-gray-500 mt-0.5">Distribution platform</p>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Channel
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Orders
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Revenue
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    AOV
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :if={@by_channel == []}>
                  <td colspan="4" class="px-6 py-6 text-center text-gray-500 text-sm">
                    No channel data yet.
                  </td>
                </tr>
                <tr :for={row <- @by_channel} class="hover:bg-gray-50">
                  <td class="px-6 py-3 text-sm text-gray-900">
                    <span class="inline-flex items-center gap-1.5">
                      <span class={[
                        "inline-block w-2 h-2 rounded-full",
                        channel_color(row["ch"])
                      ]}>
                      </span>
                      {row["ch"]}
                    </span>
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row["orders"]))}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {Spectabas.Currency.format(row["rev"], @site.currency)}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-500 text-right tabular-nums">
                    {Spectabas.Currency.format(row["aov"], @site.currency)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-6 py-4 border-b border-gray-200">
              <h2 class="text-lg font-semibold text-gray-900">By Source</h2>
              <p class="text-xs text-gray-500 mt-0.5">UI element that led to purchase</p>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Source
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Orders
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Revenue
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    AOV
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :if={@by_source == []}>
                  <td colspan="4" class="px-6 py-6 text-center text-gray-500 text-sm">
                    No source data yet.
                  </td>
                </tr>
                <tr :for={row <- @by_source} class="hover:bg-gray-50">
                  <td class="px-6 py-3 text-sm text-gray-900">{row["src"]}</td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row["orders"]))}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {Spectabas.Currency.format(row["rev"], @site.currency)}
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-500 text-right tabular-nums">
                    {Spectabas.Currency.format(row["aov"], @site.currency)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900">Top Products</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Product
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Quantity
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Revenue
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@top_products == []}>
                <td colspan="3" class="px-6 py-8 text-center text-gray-500">No product data yet.</td>
              </tr>
              <tr :for={product <- @top_products} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm text-gray-900">
                  {product["name"] || "Unknown"}
                  <span
                    :if={product["category"] && product["category"] != ""}
                    class="ml-2 text-xs px-1.5 py-0.5 rounded bg-gray-100 text-gray-600"
                  >
                    {product["category"]}
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(product["quantity"]))}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {Spectabas.Currency.format(product["revenue"], @site.currency)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Recent Orders --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto mt-6">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900">Recent Orders</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Order ID
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Revenue
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Channel
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Source
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Items
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Time
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@orders == []}>
                <td colspan="7" class="px-6 py-8 text-center text-gray-500">
                  No orders yet.
                </td>
              </tr>
              <tr :for={order <- @orders} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-mono text-gray-900">
                  {order["order_id"]}
                </td>
                <td class="px-6 py-4 text-sm">
                  <.link
                    :if={order["visitor_id"] && order["visitor_id"] != ""}
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{order["visitor_id"]}"}
                    class="text-indigo-600 hover:text-indigo-800"
                  >
                    {case @email_map[order["visitor_id"]] do
                      %{email: email} when email != "" and not is_nil(email) -> email
                      _ -> String.slice(order["visitor_id"] || "", 0, 8) <> "..."
                    end}
                  </.link>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums font-medium">
                  {Spectabas.Currency.format(order["revenue"], @site.currency)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  <span
                    :if={order["channel"] && order["channel"] != ""}
                    class="text-xs px-1.5 py-0.5 rounded bg-gray-100 text-gray-700"
                  >
                    {order["channel"]}
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  {order["source"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  {parse_items_summary(order["items"])}
                </td>
                <td class="px-6 py-4 text-xs text-gray-500">
                  {order["timestamp"]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp parse_items_summary(nil), do: "—"
  defp parse_items_summary(""), do: "—"
  defp parse_items_summary("[]"), do: "—"

  defp parse_items_summary(items_json) when is_binary(items_json) do
    case Jason.decode(items_json) do
      {:ok, items} when is_list(items) ->
        items
        |> Enum.map(fn item ->
          name = item["name"] || "?"
          qty = item["quantity"] || 1
          cat = item["category"]
          if cat && cat != "", do: "#{qty}x #{name} (#{cat})", else: "#{qty}x #{name}"
        end)
        |> Enum.join(", ")

      _ ->
        "—"
    end
  end

  defp parse_items_summary(_), do: "—"

  defp channel_color("web"), do: "bg-blue-500"
  defp channel_color("ios_iap"), do: "bg-orange-500"
  defp channel_color("android_iap"), do: "bg-green-500"
  defp channel_color(_), do: "bg-gray-400"
end
