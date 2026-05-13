defmodule SpectabasWeb.Dashboard.MrrLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, MRR, DashboardSnapshots}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Revenue & Subscriptions - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:revenue_stats, %{})
        |> assign(:monthly_revenue, [])
        |> assign(:mrr_stats, %{})
        |> assign(:mrr_trend, [])
        |> assign(:plans, [])
        |> assign(:subscriptions, [])
        |> assign(:recent_churn, [])
        |> assign(:renewals_by_month, [])
        |> assign(:has_data, false)
        |> assign(:has_subs, false)
        |> assign(:snapshot_refreshed_at, nil)
        |> assign(:loading, true)

      if connected?(socket) do
        send(self(), :load_data)
      end

      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    site = socket.assigns.site

    {revenue_stats, monthly_revenue, mrr_stats, mrr_trend, plans, subscriptions, recent_churn,
     renewals_by_month, refreshed_at} = load_widgets(site)

    has_revenue = to_float(revenue_stats["gross_revenue"] || "0") > 0
    has_subs = to_num(mrr_stats["total_subs"] || "0") > 0

    socket
    |> assign(:revenue_stats, revenue_stats)
    |> assign(:monthly_revenue, monthly_revenue)
    |> assign(:mrr_stats, mrr_stats)
    |> assign(:mrr_trend, mrr_trend)
    |> assign(:plans, plans)
    |> assign(:subscriptions, subscriptions)
    |> assign(:recent_churn, recent_churn)
    |> assign(:renewals_by_month, renewals_by_month)
    |> assign(:has_data, has_revenue or has_subs)
    |> assign(:has_subs, has_subs)
    |> assign(:snapshot_refreshed_at, refreshed_at)
  end

  # MRR has no user-selectable filters — there's only one config to
  # snapshot. Read from PG on every mount; the natural hourly cron
  # keeps it fresh. Falls back to live CH only when the snapshot
  # row doesn't exist yet (new site / first deploy).
  defp load_widgets(site) do
    case DashboardSnapshots.fetch(site, "mrr") do
      {data, refreshed_at} ->
        {
          Map.get(data, "revenue_stats", %{}),
          Map.get(data, "monthly_revenue", []),
          Map.get(data, "mrr_stats", %{}),
          Map.get(data, "mrr_trend", []),
          Map.get(data, "plans", []),
          Map.get(data, "subscriptions", []),
          Map.get(data, "recent_churn", []),
          Map.get(data, "renewals_by_month", []),
          refreshed_at
        }

      nil ->
        live_load_widgets(site)
    end
  end

  defp live_load_widgets(site) do
    {
      MRR.revenue_stats(site),
      MRR.monthly_revenue(site),
      MRR.mrr_stats(site),
      MRR.mrr_trend(site),
      MRR.plans(site),
      MRR.subscriptions(site),
      MRR.recent_churn(site),
      MRR.renewals_by_month(site),
      nil
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout flash={@flash} site={@site} active="mrr">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Revenue & Subscriptions</h1>
            <p class="text-sm text-gray-500 mt-1">All charges, refunds, and recurring revenue</p>
            <p :if={@snapshot_refreshed_at} class="text-xs text-gray-400 mt-1">
              Snapshot · last update {DashboardSnapshots.refreshed_label(@snapshot_refreshed_at)}
            </p>
          </div>
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/settings"}
            class="text-sm text-indigo-600 hover:text-indigo-800 font-medium"
          >
            Manage Integrations &rarr;
          </.link>
        </div>

        <%= if @loading do %>
          <div class="bg-white rounded-lg shadow p-10 text-center">
            <div class="text-lg text-gray-500">Loading revenue data...</div>
          </div>
        <% else %>
          <%= if !@has_data do %>
            <div class="bg-white rounded-lg shadow p-10 text-center">
              <h2 class="text-lg font-semibold text-gray-900 mb-2">No revenue data yet</h2>
              <p class="text-sm text-gray-600 max-w-md mx-auto mb-4">
                Connect Stripe or Braintree from <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/settings"}
                  class="text-indigo-600 underline"
                >Site Settings</.link>,
                then click Sync Now.
              </p>
            </div>
          <% else %>
            <%!-- Revenue Overview Cards --%>
            <div class="grid grid-cols-2 lg:grid-cols-5 gap-4 mb-8">
              <div class="bg-white rounded-lg shadow p-5 border-t-4 border-green-500">
                <dt class="text-sm font-medium text-gray-500 mb-1">Net Revenue</dt>
                <dd class="text-3xl font-bold text-green-700">
                  {Spectabas.Currency.format(
                    to_float(@revenue_stats["net_revenue"] || "0"),
                    @site.currency
                  )}
                </dd>
                <dd class="text-xs text-gray-400 mt-1">all time</dd>
              </div>
              <div class="bg-white rounded-lg shadow p-5">
                <dt class="text-sm font-medium text-gray-500 mb-1">Orders</dt>
                <dd class="text-3xl font-bold text-gray-900">
                  {format_number(@revenue_stats["total_orders"] || "0")}
                </dd>
              </div>
              <div class="bg-white rounded-lg shadow p-5">
                <dt class="text-sm font-medium text-gray-500 mb-1">Avg Order</dt>
                <dd class="text-3xl font-bold text-gray-900">
                  {Spectabas.Currency.format(
                    to_float(@revenue_stats["avg_order"] || "0"),
                    @site.currency
                  )}
                </dd>
              </div>
              <div class="bg-white rounded-lg shadow p-5">
                <dt class="text-sm font-medium text-gray-500 mb-1">Gross</dt>
                <dd class="text-3xl font-bold text-gray-900">
                  {Spectabas.Currency.format(
                    to_float(@revenue_stats["gross_revenue"] || "0"),
                    @site.currency
                  )}
                </dd>
              </div>
              <div class="bg-white rounded-lg shadow p-5">
                <dt class="text-sm font-medium text-gray-500 mb-1">Refunds</dt>
                <dd class={"text-3xl font-bold " <> if(to_float(@revenue_stats["total_refunds"] || "0") > 0, do: "text-red-600", else: "text-gray-900")}>
                  {Spectabas.Currency.format(
                    to_float(@revenue_stats["total_refunds"] || "0"),
                    @site.currency
                  )}
                </dd>
              </div>
            </div>

            <%!-- Monthly Revenue Chart --%>
            <%= if @monthly_revenue != [] do %>
              <div class="bg-white rounded-lg shadow p-6 mb-8">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">Monthly Revenue</h2>
                <div class="space-y-1.5">
                  <% max_rev =
                    @monthly_revenue
                    |> Enum.map(&to_float(&1["net_revenue"]))
                    |> Enum.max(fn -> 1 end) %>
                  <%= for point <- @monthly_revenue do %>
                    <% pct =
                      if max_rev > 0, do: to_float(point["net_revenue"]) / max_rev * 100, else: 0 %>
                    <div class="flex items-center gap-3">
                      <span class="text-sm text-gray-500 w-20 shrink-0 font-mono">
                        {String.slice(point["month"] || "", 0, 7)}
                      </span>
                      <div class="flex-1 bg-gray-100 rounded h-6 overflow-hidden">
                        <div class="bg-indigo-500 h-6 rounded transition-all" style={"width: #{pct}%"}>
                        </div>
                      </div>
                      <span class="text-sm font-semibold text-gray-900 w-28 text-right shrink-0">
                        {Spectabas.Currency.format(to_float(point["net_revenue"]), @site.currency)}
                      </span>
                      <span class="text-xs text-gray-400 w-20 text-right shrink-0">
                        {format_number(point["orders"])} orders
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Subscription Section --%>
            <%= if @has_subs do %>
              <div class="border-t-2 border-purple-200 pt-8 mb-6">
                <h2 class="text-xl font-bold text-gray-900 mb-1">Subscription Metrics</h2>
                <p class="text-sm text-gray-500 mb-6">
                  Monthly recurring revenue from active subscriptions
                </p>
              </div>

              <div class="grid grid-cols-2 lg:grid-cols-5 gap-4 mb-8">
                <div class="bg-white rounded-lg shadow p-5 border-t-4 border-purple-500">
                  <dt class="text-sm font-medium text-gray-500 mb-1">MRR</dt>
                  <dd class="text-3xl font-bold text-purple-700">
                    {Spectabas.Currency.format(
                      to_float(@mrr_stats["total_mrr"] || "0"),
                      @site.currency
                    )}
                  </dd>
                </div>
                <div class="bg-white rounded-lg shadow p-5">
                  <dt class="text-sm font-medium text-gray-500 mb-1">Active</dt>
                  <dd class="text-3xl font-bold text-gray-900">
                    {format_number(@mrr_stats["active_subs"] || "0")}
                  </dd>
                  <dd class="text-xs text-gray-400 mt-1">subscriptions</dd>
                </div>
                <div class="bg-white rounded-lg shadow p-5">
                  <dt class="text-sm font-medium text-gray-500 mb-1">Avg MRR</dt>
                  <dd class="text-3xl font-bold text-gray-900">
                    {Spectabas.Currency.format(
                      to_float(@mrr_stats["avg_mrr_per_sub"] || "0"),
                      @site.currency
                    )}
                  </dd>
                  <dd class="text-xs text-gray-400 mt-1">per subscriber</dd>
                </div>
                <div class="bg-white rounded-lg shadow p-5">
                  <dt class="text-sm font-medium text-gray-500 mb-1">Past Due</dt>
                  <dd class={"text-3xl font-bold " <> if(to_num(@mrr_stats["past_due_subs"] || "0") > 0, do: "text-amber-600", else: "text-gray-900")}>
                    {format_number(@mrr_stats["past_due_subs"] || "0")}
                  </dd>
                </div>
                <div class="bg-white rounded-lg shadow p-5">
                  <dt class="text-sm font-medium text-gray-500 mb-1">Canceled</dt>
                  <dd class={"text-3xl font-bold " <> if(to_num(@mrr_stats["canceled_subs"] || "0") > 0, do: "text-red-600", else: "text-gray-900")}>
                    {format_number(@mrr_stats["canceled_subs"] || "0")}
                  </dd>
                </div>
              </div>

              <%!-- MRR Trend --%>
              <%= if @mrr_trend != [] do %>
                <div class="bg-white rounded-lg shadow p-6 mb-8">
                  <h2 class="text-lg font-semibold text-gray-900 mb-4">MRR Trend</h2>
                  <div class="space-y-1.5">
                    <% max_mrr = @mrr_trend |> Enum.map(&to_float(&1["mrr"])) |> Enum.max(fn -> 1 end) %>
                    <%= for point <- @mrr_trend do %>
                      <% pct = if max_mrr > 0, do: to_float(point["mrr"]) / max_mrr * 100, else: 0 %>
                      <div class="flex items-center gap-3">
                        <span class="text-sm text-gray-500 w-24 shrink-0 font-mono">
                          {point["date"]}
                        </span>
                        <div class="flex-1 bg-gray-100 rounded h-6 overflow-hidden">
                          <div
                            class="bg-purple-500 h-6 rounded transition-all"
                            style={"width: #{pct}%"}
                          >
                          </div>
                        </div>
                        <span class="text-sm font-semibold text-gray-900 w-28 text-right shrink-0">
                          {Spectabas.Currency.format(to_float(point["mrr"]), @site.currency)}
                        </span>
                        <span class="text-xs text-gray-400 w-16 text-right shrink-0">
                          {format_number(point["subs"])} subs
                        </span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
                <%!-- Plan Breakdown --%>
                <div class="bg-white rounded-lg shadow p-6">
                  <h2 class="text-lg font-semibold text-gray-900 mb-4">Plan Breakdown</h2>
                  <%= if @plans == [] do %>
                    <p class="text-sm text-gray-500">No active plans.</p>
                  <% else %>
                    <table class="w-full">
                      <thead>
                        <tr class="border-b-2 border-gray-200">
                          <th class="text-left py-3 text-sm font-semibold text-gray-700">Plan</th>
                          <th class="text-left py-3 text-sm font-semibold text-gray-700">Billing</th>
                          <th class="text-right py-3 text-sm font-semibold text-gray-700">Subs</th>
                          <th class="text-right py-3 text-sm font-semibold text-gray-700">MRR</th>
                        </tr>
                      </thead>
                      <tbody>
                        <% total_plan_mrr =
                          @plans |> Enum.map(&to_float(&1["plan_mrr"])) |> Enum.sum() %>
                        <%= for plan <- @plans do %>
                          <% plan_pct =
                            if total_plan_mrr > 0,
                              do: Float.round(to_float(plan["plan_mrr"]) / total_plan_mrr * 100, 1),
                              else: 0 %>
                          <tr class="border-b border-gray-100 hover:bg-gray-50">
                            <td class="py-3 font-medium text-gray-900">
                              {plan["plan_name"] || "(unnamed)"}
                            </td>
                            <td class="py-3">
                              <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full " <>
                            if(plan["plan_interval"] == "year", do: "bg-blue-100 text-blue-700", else: "bg-gray-100 text-gray-600")}>
                                {plan["plan_interval"]}
                              </span>
                            </td>
                            <td class="text-right py-3 text-sm">
                              {format_number(plan["sub_count"])}
                            </td>
                            <td class="text-right py-3">
                              <div class="font-semibold text-purple-700">
                                {Spectabas.Currency.format(to_float(plan["plan_mrr"]), @site.currency)}
                              </div>
                              <div class="text-xs text-gray-400">{plan_pct}%</div>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  <% end %>
                </div>

                <%!-- Recent Cancellations --%>
                <div class="bg-white rounded-lg shadow p-6">
                  <h2 class="text-lg font-semibold text-gray-900 mb-4">
                    Recent Cancellations <span class="text-sm font-normal text-gray-400">(30d)</span>
                  </h2>
                  <%= if @recent_churn == [] do %>
                    <p class="text-sm text-gray-500">No cancellations in the last 30 days.</p>
                  <% else %>
                    <table class="w-full">
                      <thead>
                        <tr class="border-b-2 border-gray-200">
                          <th class="text-left py-3 text-sm font-semibold text-gray-700">Customer</th>
                          <th class="text-left py-3 text-sm font-semibold text-gray-700">Plan</th>
                          <th class="text-right py-3 text-sm font-semibold text-gray-700">
                            Lost MRR
                          </th>
                          <th class="text-right py-3 text-sm font-semibold text-gray-700">Date</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for sub <- @recent_churn do %>
                          <tr class="border-b border-gray-100 hover:bg-gray-50">
                            <td class="py-3 text-sm">{sub["customer_email"] || "—"}</td>
                            <td class="py-3 text-sm text-gray-500">{sub["plan_name"] || "—"}</td>
                            <td class="text-right py-3 text-sm font-semibold text-red-600">
                              -{Spectabas.Currency.format(
                                to_float(sub["mrr_amount"]),
                                sub["currency"] || @site.currency
                              )}
                            </td>
                            <td class="text-right py-3 text-sm text-gray-500">
                              {format_date(sub["canceled_at"])}
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  <% end %>
                </div>
              </div>

              <%!-- Upcoming Renewals --%>
              <%= if @renewals_by_month != [] do %>
                <div class="bg-white rounded-lg shadow p-6 mb-8">
                  <h2 class="text-lg font-semibold text-gray-900 mb-2">Upcoming Renewals</h2>
                  <p class="text-sm text-gray-500 mb-4">
                    Expected billing by month based on current subscription renewal dates
                  </p>
                  <table class="w-full">
                    <thead>
                      <tr class="border-b-2 border-gray-200">
                        <th class="text-left py-3 text-sm font-semibold text-gray-700">Month</th>
                        <th class="text-right py-3 text-sm font-semibold text-gray-700">Renewals</th>
                        <th class="text-right py-3 text-sm font-semibold text-gray-700">
                          Expected Billing
                        </th>
                        <th class="text-right py-3 text-sm font-semibold text-gray-700">
                          MRR at Stake
                        </th>
                        <th class="text-center py-3 text-sm font-semibold text-gray-700">
                          Includes Annual
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for r <- @renewals_by_month do %>
                        <tr class="border-b border-gray-100 hover:bg-gray-50">
                          <td class="py-3 text-sm font-medium">
                            {String.slice(r["month"] || "", 0, 7)}
                          </td>
                          <td class="text-right py-3 text-sm">{r["sub_count"]}</td>
                          <td class="text-right py-3 text-sm font-semibold text-gray-900">
                            {Spectabas.Currency.format(r["billing_amount"], @site.currency)}
                          </td>
                          <td class="text-right py-3 text-sm text-amber-600">
                            {Spectabas.Currency.format(r["mrr_at_risk"], @site.currency)}/mo
                          </td>
                          <td class="text-center py-3">
                            <%= if r["has_annual"] do %>
                              <span class="inline-block px-2 py-0.5 text-xs font-medium rounded-full bg-blue-100 text-blue-700">
                                Annual
                              </span>
                            <% end %>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>

              <%!-- All Subscriptions --%>
              <div class="bg-white rounded-lg shadow p-6">
                <h2 class="text-lg font-semibold text-gray-900 mb-4">
                  All Subscriptions
                  <span class="text-sm font-normal text-gray-400">({length(@subscriptions)})</span>
                </h2>
                <div class="overflow-x-auto">
                  <table class="w-full">
                    <thead>
                      <tr class="border-b-2 border-gray-200">
                        <th class="text-left py-3 text-sm font-semibold text-gray-700">Customer</th>
                        <th class="text-left py-3 text-sm font-semibold text-gray-700">Plan</th>
                        <th class="text-right py-3 text-sm font-semibold text-gray-700">MRR</th>
                        <th class="text-center py-3 text-sm font-semibold text-gray-700">Status</th>
                        <th class="text-right py-3 text-sm font-semibold text-gray-700">Started</th>
                        <th class="text-right py-3 text-sm font-semibold text-gray-700">Renews</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for sub <- @subscriptions do %>
                        <tr class="border-b border-gray-100 hover:bg-gray-50">
                          <td class="py-3 text-sm">{sub["customer_email"] || "—"}</td>
                          <td class="py-3 text-sm text-gray-600">{sub["plan_name"] || "—"}</td>
                          <td class="text-right py-3 text-sm font-semibold">
                            {Spectabas.Currency.format(
                              to_float(sub["mrr_amount"]),
                              sub["currency"] || @site.currency
                            )}
                          </td>
                          <td class="text-center py-3">
                            <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full " <> status_color(sub["status"])}>
                              {sub["status"]}
                            </span>
                          </td>
                          <td class="text-right py-3 text-sm text-gray-500">
                            {format_date(sub["started_at"])}
                          </td>
                          <td class="text-right py-3 text-sm text-gray-500">
                            {format_date(sub["current_period_end"])}
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp status_color("active"), do: "bg-green-100 text-green-700"
  defp status_color("trialing"), do: "bg-blue-100 text-blue-700"
  defp status_color("past_due"), do: "bg-amber-100 text-amber-700"
  defp status_color("canceled"), do: "bg-red-100 text-red-700"
  defp status_color(_), do: "bg-gray-100 text-gray-600"

  defp format_date(nil), do: "—"
  defp format_date(""), do: "—"
  defp format_date("1970-01-01" <> _), do: "—"
  defp format_date(dt) when is_binary(dt), do: String.slice(dt, 0, 10)
end
