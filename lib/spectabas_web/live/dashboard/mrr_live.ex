defmodule SpectabasWeb.Dashboard.MrrLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, ClickHouse}
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
       |> assign(:page_title, "MRR & Subscriptions - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> load_data()}
    end
  end

  defp load_data(socket) do
    site = socket.assigns.site
    site_p = ClickHouse.param(site.id)

    # Current MRR from latest subscription snapshots
    mrr_sql = """
    SELECT
      sum(mrr_amount) AS total_mrr,
      countIf(status = 'active') AS active_subs,
      countIf(status = 'canceled') AS canceled_subs,
      countIf(status = 'past_due') AS past_due_subs,
      avg(mrr_amount) AS avg_mrr_per_sub
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
      AND status IN ('active', 'past_due', 'trialing')
    """

    mrr_stats =
      case ClickHouse.query(mrr_sql) do
        {:ok, [row | _]} -> row
        _ -> %{}
      end

    # MRR trend over last 30 days
    trend_sql = """
    SELECT
      snapshot_date AS date,
      sum(mrr_amount) AS mrr
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date >= today() - 30
      AND status IN ('active', 'past_due', 'trialing')
    GROUP BY snapshot_date
    ORDER BY snapshot_date ASC
    """

    mrr_trend =
      case ClickHouse.query(trend_sql) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Plan breakdown
    plan_sql = """
    SELECT
      plan_name,
      plan_interval,
      count() AS sub_count,
      sum(mrr_amount) AS plan_mrr
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
      AND status IN ('active', 'past_due', 'trialing')
    GROUP BY plan_name, plan_interval
    ORDER BY plan_mrr DESC
    """

    plans =
      case ClickHouse.query(plan_sql) do
        {:ok, rows} -> rows
        _ -> []
      end

    # Recent cancellations (last 30 days)
    churn_sql = """
    SELECT
      subscription_id,
      customer_email,
      plan_name,
      mrr_amount,
      currency,
      canceled_at
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND status = 'canceled'
      AND canceled_at >= now() - INTERVAL 30 DAY
      AND canceled_at > toDateTime(0)
    ORDER BY canceled_at DESC
    LIMIT 20
    """

    recent_churn =
      case ClickHouse.query(churn_sql) do
        {:ok, rows} -> rows
        _ -> []
      end

    socket
    |> assign(:mrr_stats, mrr_stats)
    |> assign(:mrr_trend, mrr_trend)
    |> assign(:plans, plans)
    |> assign(:recent_churn, recent_churn)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout site={@site}>
      <h1 class="text-2xl font-bold text-gray-900 mb-6">MRR & Subscriptions</h1>

      <%!-- MRR Overview Cards --%>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
        <div class="bg-white rounded-lg shadow p-5">
          <dt class="text-sm font-medium text-gray-500">Monthly Recurring Revenue</dt>
          <dd class="mt-1 text-3xl font-bold text-green-700">
            {Spectabas.Currency.format(to_float(@mrr_stats["total_mrr"] || "0"), @site.currency)}
          </dd>
        </div>
        <div class="bg-white rounded-lg shadow p-5">
          <dt class="text-sm font-medium text-gray-500">Active Subscriptions</dt>
          <dd class="mt-1 text-3xl font-bold text-gray-900">
            {to_num(@mrr_stats["active_subs"] || "0")}
          </dd>
        </div>
        <div class="bg-white rounded-lg shadow p-5">
          <dt class="text-sm font-medium text-gray-500">Avg MRR / Subscriber</dt>
          <dd class="mt-1 text-3xl font-bold text-gray-900">
            {Spectabas.Currency.format(to_float(@mrr_stats["avg_mrr_per_sub"] || "0"), @site.currency)}
          </dd>
        </div>
        <div class="bg-white rounded-lg shadow p-5">
          <dt class="text-sm font-medium text-gray-500">Past Due</dt>
          <dd class="mt-1 text-3xl font-bold text-amber-600">
            {to_num(@mrr_stats["past_due_subs"] || "0")}
          </dd>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
        <%!-- Plan Breakdown --%>
        <div class="bg-white rounded-lg shadow p-5">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Plan Breakdown</h2>
          <%= if @plans == [] do %>
            <p class="text-sm text-gray-500">
              No subscription data yet. Connect Stripe and sync to see plan breakdown.
            </p>
          <% else %>
            <table class="w-full text-sm">
              <thead class="border-b border-gray-200">
                <tr>
                  <th class="text-left py-2 font-medium text-gray-700">Plan</th>
                  <th class="text-left py-2 font-medium text-gray-700">Interval</th>
                  <th class="text-right py-2 font-medium text-gray-700">Subscribers</th>
                  <th class="text-right py-2 font-medium text-gray-700">MRR</th>
                </tr>
              </thead>
              <tbody>
                <%= for plan <- @plans do %>
                  <tr class="border-b border-gray-100">
                    <td class="py-2 font-medium">{plan["plan_name"] || "(unnamed)"}</td>
                    <td class="py-2 text-gray-500">{plan["plan_interval"]}</td>
                    <td class="text-right py-2">{to_num(plan["sub_count"])}</td>
                    <td class="text-right py-2 font-medium text-green-700">
                      {Spectabas.Currency.format(to_float(plan["plan_mrr"]), @site.currency)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>

        <%!-- Recent Cancellations --%>
        <div class="bg-white rounded-lg shadow p-5">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Recent Cancellations (30d)</h2>
          <%= if @recent_churn == [] do %>
            <p class="text-sm text-gray-500">No cancellations in the last 30 days.</p>
          <% else %>
            <table class="w-full text-sm">
              <thead class="border-b border-gray-200">
                <tr>
                  <th class="text-left py-2 font-medium text-gray-700">Customer</th>
                  <th class="text-left py-2 font-medium text-gray-700">Plan</th>
                  <th class="text-right py-2 font-medium text-gray-700">Lost MRR</th>
                  <th class="text-right py-2 font-medium text-gray-700">Date</th>
                </tr>
              </thead>
              <tbody>
                <%= for sub <- @recent_churn do %>
                  <tr class="border-b border-gray-100">
                    <td class="py-2 text-gray-700">{sub["customer_email"] || "—"}</td>
                    <td class="py-2 text-gray-500">{sub["plan_name"] || "—"}</td>
                    <td class="text-right py-2 font-medium text-red-600">
                      -{Spectabas.Currency.format(
                        to_float(sub["mrr_amount"]),
                        sub["currency"] || @site.currency
                      )}
                    </td>
                    <td class="text-right py-2 text-gray-500">
                      {String.slice(sub["canceled_at"] || "", 0, 10)}
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>

      <%!-- MRR Trend --%>
      <div class="bg-white rounded-lg shadow p-5">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">MRR Trend (Last 30 Days)</h2>
        <%= if @mrr_trend == [] do %>
          <p class="text-sm text-gray-500">
            No MRR data yet. Subscription snapshots are taken daily when Stripe is connected.
          </p>
        <% else %>
          <div class="grid grid-cols-1 gap-1">
            <%= for point <- @mrr_trend do %>
              <div class="flex items-center gap-3 text-sm">
                <span class="text-gray-500 w-24">{point["date"]}</span>
                <div class="flex-1 bg-gray-100 rounded-full h-4 overflow-hidden">
                  <% max_mrr = @mrr_trend |> Enum.map(&to_float(&1["mrr"])) |> Enum.max(fn -> 1 end) %>
                  <% pct = if max_mrr > 0, do: to_float(point["mrr"]) / max_mrr * 100, else: 0 %>
                  <div class="bg-green-500 h-4 rounded-full" style={"width: #{pct}%"}></div>
                </div>
                <span class="font-medium text-gray-900 w-28 text-right">
                  {Spectabas.Currency.format(to_float(point["mrr"]), @site.currency)}
                </span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end
end
