defmodule SpectabasWeb.Dashboard.EcommerceLive do
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

    stats =
      case Analytics.ecommerce_stats(site, user, range_to_atom(range)) do
        {:ok, data} ->
          data

        _ ->
          %{
            total_revenue: Decimal.new(0),
            total_orders: 0,
            avg_order_value: Decimal.new(0),
            top_products: []
          }
      end

    assign(socket, :ecommerce, stats)
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
              {@site.currency} {format_money(@ecommerce.total_revenue)}
            </dd>
          </div>
          <div class="bg-white rounded-lg shadow p-6">
            <dt class="text-sm font-medium text-gray-500">Orders</dt>
            <dd class="mt-1 text-3xl font-bold text-gray-900">{@ecommerce.total_orders}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-6">
            <dt class="text-sm font-medium text-gray-500">Avg Order Value</dt>
            <dd class="mt-1 text-3xl font-bold text-gray-900">
              {@site.currency} {format_money(@ecommerce.avg_order_value)}
            </dd>
          </div>
        </div>

        <div class="bg-white rounded-lg shadow overflow-hidden">
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
              <tr :if={Map.get(@ecommerce, :top_products, []) == []}>
                <td colspan="3" class="px-6 py-8 text-center text-gray-500">No product data yet.</td>
              </tr>
              <tr :for={product <- Map.get(@ecommerce, :top_products, [])} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm text-gray-900">{Map.get(product, "name", "Unknown")}</td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {Map.get(product, "quantity", 0)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {@site.currency} {format_money(Map.get(product, "revenue", 0))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp format_money(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  defp format_money(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp format_money(_), do: "0.00"
end
