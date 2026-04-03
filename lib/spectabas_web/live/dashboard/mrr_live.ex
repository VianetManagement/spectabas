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
      countIf(status = 'trialing') AS trialing_subs,
      if(countIf(status IN ('active', 'past_due', 'trialing')) > 0,
        round(sum(mrr_amount) / countIf(status IN ('active', 'past_due', 'trialing')), 2),
        0) AS avg_mrr_per_sub,
      count() AS total_subs
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
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
      sum(mrr_amount) AS mrr,
      countIf(status IN ('active', 'past_due', 'trialing')) AS subs
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

    # All subscriptions (latest snapshot)
    subs_sql = """
    SELECT
      subscription_id,
      customer_email,
      plan_name,
      plan_interval,
      mrr_amount,
      currency,
      status,
      started_at,
      canceled_at,
      current_period_end
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
    ORDER BY mrr_amount DESC
    LIMIT 100
    """

    subscriptions =
      case ClickHouse.query(subs_sql) do
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
    |> assign(:subscriptions, subscriptions)
    |> assign(:recent_churn, recent_churn)
    |> assign(:has_data, to_num(mrr_stats["total_subs"] || "0") > 0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout site={@site}>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-bold text-gray-900">MRR & Subscriptions</h1>
          <p class="text-sm text-gray-500 mt-1">
            Recurring revenue from Stripe and Braintree subscriptions
          </p>
        </div>
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/settings"}
          class="text-sm text-indigo-600 hover:text-indigo-800 font-medium"
        >
          Manage Integrations &rarr;
        </.link>
      </div>

      <%= if !@has_data do %>
        <%!-- Empty state --%>
        <div class="bg-white rounded-lg shadow p-10 text-center">
          <div class="text-4xl mb-4">📊</div>
          <h2 class="text-lg font-semibold text-gray-900 mb-2">No subscription data yet</h2>
          <p class="text-sm text-gray-600 max-w-md mx-auto mb-4">
            Connect Stripe or Braintree from your
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/settings"}
              class="text-indigo-600 underline"
            >
              Site Settings
            </.link>
            page, then click Sync Now. Subscription data will appear here after the first sync.
          </p>
          <p class="text-xs text-gray-400">
            Requires Subscriptions:Read permission on your API key.
          </p>
        </div>
      <% else %>
        <%!-- MRR Overview Cards --%>
        <div class="grid grid-cols-2 lg:grid-cols-5 gap-4 mb-8">
          <div class="bg-white rounded-lg shadow p-5 border-t-4 border-green-500">
            <dt class="text-sm font-medium text-gray-500 mb-1">MRR</dt>
            <dd class="text-3xl font-bold text-green-700">
              {Spectabas.Currency.format(to_float(@mrr_stats["total_mrr"] || "0"), @site.currency)}
            </dd>
          </div>
          <div class="bg-white rounded-lg shadow p-5">
            <dt class="text-sm font-medium text-gray-500 mb-1">Active</dt>
            <dd class="text-3xl font-bold text-gray-900">
              {to_num(@mrr_stats["active_subs"] || "0")}
            </dd>
            <dd class="text-xs text-gray-400 mt-1">subscriptions</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-5">
            <dt class="text-sm font-medium text-gray-500 mb-1">Avg Revenue</dt>
            <dd class="text-3xl font-bold text-gray-900">
              {Spectabas.Currency.format(
                to_float(@mrr_stats["avg_mrr_per_sub"] || "0"),
                @site.currency
              )}
            </dd>
            <dd class="text-xs text-gray-400 mt-1">per subscriber / mo</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-5">
            <dt class="text-sm font-medium text-gray-500 mb-1">Past Due</dt>
            <dd class={"text-3xl font-bold " <> if(to_num(@mrr_stats["past_due_subs"] || "0") > 0, do: "text-amber-600", else: "text-gray-900")}>
              {to_num(@mrr_stats["past_due_subs"] || "0")}
            </dd>
            <dd class="text-xs text-gray-400 mt-1">at risk</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-5">
            <dt class="text-sm font-medium text-gray-500 mb-1">Canceled</dt>
            <dd class={"text-3xl font-bold " <> if(to_num(@mrr_stats["canceled_subs"] || "0") > 0, do: "text-red-600", else: "text-gray-900")}>
              {to_num(@mrr_stats["canceled_subs"] || "0")}
            </dd>
            <dd class="text-xs text-gray-400 mt-1">total</dd>
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
                  <span class="text-sm text-gray-500 w-24 shrink-0 font-mono">{point["date"]}</span>
                  <div class="flex-1 bg-gray-100 rounded h-6 overflow-hidden">
                    <div class="bg-green-500 h-6 rounded transition-all" style={"width: #{pct}%"}>
                    </div>
                  </div>
                  <span class="text-sm font-semibold text-gray-900 w-32 text-right shrink-0">
                    {Spectabas.Currency.format(to_float(point["mrr"]), @site.currency)}
                  </span>
                  <span class="text-xs text-gray-400 w-16 text-right shrink-0">
                    {to_num(point["subs"])} subs
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
              <p class="text-sm text-gray-500">No active plans found.</p>
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
                  <% total_plan_mrr = @plans |> Enum.map(&to_float(&1["plan_mrr"])) |> Enum.sum() %>
                  <%= for plan <- @plans do %>
                    <% plan_pct =
                      if total_plan_mrr > 0,
                        do: Float.round(to_float(plan["plan_mrr"]) / total_plan_mrr * 100, 1),
                        else: 0 %>
                    <tr class="border-b border-gray-100 hover:bg-gray-50">
                      <td class="py-3">
                        <span class="font-medium text-gray-900">
                          {plan["plan_name"] || "(unnamed)"}
                        </span>
                      </td>
                      <td class="py-3">
                        <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full " <>
                          if(plan["plan_interval"] == "year", do: "bg-blue-100 text-blue-700", else: "bg-gray-100 text-gray-600")}>
                          {plan["plan_interval"]}
                        </span>
                      </td>
                      <td class="text-right py-3 text-sm text-gray-700">
                        {to_num(plan["sub_count"])}
                      </td>
                      <td class="text-right py-3">
                        <div class="font-semibold text-green-700">
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
              Recent Cancellations <span class="text-sm font-normal text-gray-400">(30 days)</span>
            </h2>
            <%= if @recent_churn == [] do %>
              <p class="text-sm text-gray-500">No cancellations in the last 30 days.</p>
            <% else %>
              <table class="w-full">
                <thead>
                  <tr class="border-b-2 border-gray-200">
                    <th class="text-left py-3 text-sm font-semibold text-gray-700">Customer</th>
                    <th class="text-left py-3 text-sm font-semibold text-gray-700">Plan</th>
                    <th class="text-right py-3 text-sm font-semibold text-gray-700">Lost MRR</th>
                    <th class="text-right py-3 text-sm font-semibold text-gray-700">Date</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for sub <- @recent_churn do %>
                    <tr class="border-b border-gray-100 hover:bg-gray-50">
                      <td class="py-3 text-sm text-gray-800">{sub["customer_email"] || "—"}</td>
                      <td class="py-3 text-sm text-gray-500">{sub["plan_name"] || "—"}</td>
                      <td class="text-right py-3 text-sm font-semibold text-red-600">
                        -{Spectabas.Currency.format(
                          to_float(sub["mrr_amount"]),
                          sub["currency"] || @site.currency
                        )}
                      </td>
                      <td class="text-right py-3 text-sm text-gray-500">
                        {String.slice(sub["canceled_at"] || "", 0, 10)}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>

        <%!-- All Subscriptions Table --%>
        <div class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">
            All Subscriptions
            <span class="text-sm font-normal text-gray-400">({length(@subscriptions)} total)</span>
          </h2>
          <%= if @subscriptions == [] do %>
            <p class="text-sm text-gray-500">No subscriptions found.</p>
          <% else %>
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
                      <td class="py-3 text-sm">
                        <span class="text-gray-900">{sub["customer_email"] || "—"}</span>
                      </td>
                      <td class="py-3 text-sm text-gray-600">{sub["plan_name"] || "—"}</td>
                      <td class="text-right py-3 text-sm font-semibold text-gray-900">
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
          <% end %>
        </div>
      <% end %>
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

  defp format_date(dt) when is_binary(dt) do
    String.slice(dt, 0, 10)
  end
end
