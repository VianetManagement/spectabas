defmodule Spectabas.MRR do
  @moduledoc """
  ClickHouse queries that back the Revenue & Subscriptions (MRR) dashboard.

  Functions here used to live as private helpers inside
  `SpectabasWeb.Dashboard.MrrLive`. They were lifted into a context module
  so the hourly `DashboardSnapshot` worker can call them too — the page
  reads from PG instead of fanning out 8 CH queries on every mount.

  All queries take just a `Site` struct (no date range — the dashboard
  shows all-time aggregates plus a 30d MRR trend).
  """

  alias Spectabas.{Analytics, ClickHouse, Sites.Site}
  import Spectabas.TypeHelpers

  @doc "Revenue stats — all-time ecommerce_events aggregate."
  def revenue_stats(%Site{} = site) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT
      sum(revenue) - sum(refund_amount) AS net_revenue,
      sum(revenue) AS gross_revenue,
      sum(refund_amount) AS total_refunds,
      countDistinct(order_id) AS total_orders,
      round(avg(revenue), 2) AS avg_order
    FROM ecommerce_events
    WHERE site_id = #{site_p}
      #{Analytics.ecommerce_source_filter(site)}
    """

    case ch_query(sql) do
      {:ok, [row | _]} -> row
      _ -> %{}
    end
  end

  @doc "Revenue by month — all-time, grouped by site timezone."
  def monthly_revenue(%Site{} = site) do
    site_p = ClickHouse.param(site.id)
    tz_p = ClickHouse.param(site.timezone || "UTC")

    sql = """
    SELECT
      toStartOfMonth(toTimezone(timestamp, #{tz_p})) AS month,
      sum(revenue) - sum(refund_amount) AS net_revenue,
      countDistinct(order_id) AS orders
    FROM ecommerce_events
    WHERE site_id = #{site_p}
      #{Analytics.ecommerce_source_filter(site)}
    GROUP BY month
    ORDER BY month ASC
    """

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc "MRR stats from the latest subscription snapshot."
  def mrr_stats(%Site{} = site) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT
      sumIf(mrr_amount, status = 'active') AS total_mrr,
      countIf(status = 'active') AS active_subs,
      countIf(status = 'canceled') AS canceled_subs,
      countIf(status = 'past_due') AS past_due_subs,
      countIf(status = 'trialing') AS trialing_subs,
      if(countIf(status = 'active') > 0,
        round(sumIf(mrr_amount, status = 'active') / countIf(status = 'active'), 2),
        0) AS avg_mrr_per_sub,
      count() AS total_subs
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
    """

    case ch_query(sql) do
      {:ok, [row | _]} -> row
      _ -> %{}
    end
  end

  @doc "MRR trend — 30d of active-subscription snapshots."
  def mrr_trend(%Site{} = site) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT
      snapshot_date AS date,
      sum(mrr_amount) AS mrr,
      count() AS subs
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date >= today() - 30
      AND status = 'active'
    GROUP BY snapshot_date
    ORDER BY snapshot_date ASC
    """

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc "Plan breakdown — active subscriptions grouped by plan + interval."
  def plans(%Site{} = site) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT plan_name, plan_interval, count() AS sub_count, sum(mrr_amount) AS plan_mrr
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
      AND status = 'active'
    GROUP BY plan_name, plan_interval
    ORDER BY plan_mrr DESC
    """

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc "Subscription detail list — top 100 by mrr_amount."
  def subscriptions(%Site{} = site) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT subscription_id, customer_email, plan_name, plan_interval,
      mrr_amount, currency, status, started_at, canceled_at, current_period_end
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
    ORDER BY mrr_amount DESC
    LIMIT 100
    """

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc "Recent cancellations — last 30 days."
  def recent_churn(%Site{} = site) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT subscription_id, customer_email, plan_name, mrr_amount, currency, canceled_at
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND status = 'canceled'
      AND canceled_at >= now() - INTERVAL 30 DAY
      AND canceled_at > toDateTime(0)
    ORDER BY canceled_at DESC
    LIMIT 20
    """

    case ch_query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc """
  Upcoming renewals — billable amounts grouped by renewal month, then
  aggregated to one row per month (combining monthly + annual plans).
  """
  def renewals_by_month(%Site{} = site) do
    site_p = ClickHouse.param(site.id)

    sql = """
    SELECT
      toStartOfMonth(current_period_end) AS renewal_month,
      plan_interval,
      count() AS sub_count,
      sum(if(plan_interval = 'year', mrr_amount * 12, mrr_amount)) AS billing_amount,
      sum(mrr_amount) AS mrr_contribution
    FROM subscription_events FINAL
    WHERE site_id = #{site_p}
      AND snapshot_date = (SELECT max(snapshot_date) FROM subscription_events FINAL WHERE site_id = #{site_p})
      AND status IN ('active', 'past_due', 'trialing')
      AND current_period_end > now()
      AND current_period_end > toDateTime(0)
    GROUP BY renewal_month, plan_interval
    ORDER BY renewal_month ASC
    LIMIT 24
    """

    rows =
      case ch_query(sql) do
        {:ok, rows} -> rows
        _ -> []
      end

    rows
    |> Enum.group_by(& &1["renewal_month"])
    |> Enum.map(fn {month, group_rows} ->
      %{
        "month" => month,
        "sub_count" => group_rows |> Enum.map(&to_num(&1["sub_count"])) |> Enum.sum(),
        "billing_amount" => group_rows |> Enum.map(&to_float(&1["billing_amount"])) |> Enum.sum(),
        "mrr_at_risk" => group_rows |> Enum.map(&to_float(&1["mrr_contribution"])) |> Enum.sum(),
        "has_annual" => Enum.any?(group_rows, &(&1["plan_interval"] == "year"))
      }
    end)
    |> Enum.sort_by(& &1["month"])
  end

  # All MRR queries hit `subscription_events FINAL` or `ecommerce_events`,
  # both of which can have millions of rows on busy stores. Match the
  # 200_000ms receive_timeout + 180s SQL ceiling pattern used by
  # SearchKeywords and the funnel queries so a slow cold call doesn't
  # silently fall through to the zero-defaults branch.
  defp ch_query(sql) do
    ClickHouse.query(sql <> "\nSETTINGS max_execution_time = 180", receive_timeout: 200_000)
  end
end
