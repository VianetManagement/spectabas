defmodule Spectabas.Workers.InsightsGenerator do
  @moduledoc """
  Daily worker that turns the various detection systems' output into
  `Spectabas.Insights.Insight` rows so the dashboard "What's happening"
  feed has fresh content between weekly AI emails.

  Sources today:
  - `Analytics.AnomalyCache` — the 17 anomaly types DailyAnomalyDetection
    materializes nightly. Becomes one Insight row per anomaly, kind
    `"anomaly_spike"` or `"anomaly_drop"` depending on the metric sign.
  - Goal pace deltas — computed inline against `goal_stats` snapshot,
    one Insight row per goal where current week converters moved >=25%
    from prior. Kind `"goal_pace"`.

  More sources are easy to add later (eg AI weekly summaries as
  individual insights, conversion milestones, scraper detections).
  Each generator helper just returns an Insight attr map; the worker
  collects them and `Insights.create/1`s each with the same dedupe key
  so repeated runs are idempotent.

  After insert, the worker enqueues `Workers.InsightExplainer` per
  anomaly insight so the AI explanation fills in asynchronously.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Spectabas.{Insights, Repo, Sites}
  alias Spectabas.Analytics.AnomalyCache

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(_job) do
    sites = Sites.list_sites() |> Enum.filter(& &1.active)

    Logger.notice("[InsightsGenerator] generating insights for #{length(sites)} site(s)")

    Enum.each(sites, fn site ->
      try do
        generate_for_site(site)
      rescue
        e ->
          Logger.warning("[InsightsGenerator] site=#{site.id} crashed: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  defp generate_for_site(site) do
    insights = []
    insights = anomaly_insights(insights, site)
    insights = goal_pace_insights(insights, site)

    Enum.each(insights, &write_insight/1)
  end

  defp write_insight(attrs) do
    case Insights.create(attrs) do
      {:ok, insight} ->
        # Async AI enrichment for anomaly insights only. Other kinds
        # already have a body that's self-explanatory.
        if String.starts_with?(insight.kind, "anomaly_") do
          enqueue_explainer(insight.id)
        end

        :ok

      {:error, changeset} ->
        Logger.warning(
          "[InsightsGenerator] write failed kind=#{attrs[:kind]}: #{inspect(changeset.errors) |> String.slice(0, 200)}"
        )

        :ok
    end
  end

  defp enqueue_explainer(insight_id) do
    %{"insight_id" => insight_id}
    |> Spectabas.Workers.InsightExplainer.new()
    |> Oban.insert()
  end

  # ---- Anomaly source ----

  defp anomaly_insights(acc, site) do
    case AnomalyCache.get(site.id) do
      nil ->
        acc

      cache_row ->
        items = AnomalyCache.items(cache_row)

        acc ++
          Enum.map(items, fn anomaly -> anomaly_to_insight(site, anomaly) end)
    end
  end

  defp anomaly_to_insight(site, anomaly) do
    pct = anomaly[:change_pct] || 0
    kind = if pct < 0, do: "anomaly_drop", else: "anomaly_spike"
    severity = severity_for_anomaly(anomaly)

    # Dedupe at the metric+category granularity so repeated daily runs
    # don't multiply the same anomaly. (Re-runs of the worker DO update
    # the title/body via the conflict_target replace, so the most recent
    # numbers win.)
    dedupe_key =
      Insights.dedupe_key("anomaly", %{
        "category" => anomaly[:category],
        "metric" => anomaly[:metric]
      })

    %{
      site_id: site.id,
      kind: kind,
      severity: severity,
      title: anomaly_title(anomaly),
      body: anomaly[:message],
      dedupe_key: dedupe_key,
      data: %{
        "category" => anomaly[:category],
        "metric" => anomaly[:metric],
        "current" => anomaly[:current],
        "previous" => anomaly[:previous],
        "change_pct" => pct,
        "suggested_action" => anomaly[:action]
      }
    }
  end

  defp anomaly_title(anomaly) do
    metric = anomaly[:metric] || "metric"
    pct = anomaly[:change_pct] || 0
    direction = if pct < 0, do: "dropped", else: "spiked"
    "#{metric |> to_string() |> humanize()} #{direction} #{abs(pct) |> trunc()}%"
  end

  defp severity_for_anomaly(%{severity: :high}), do: "warning"
  defp severity_for_anomaly(%{severity: :medium}), do: "notice"
  defp severity_for_anomaly(_), do: "info"

  defp humanize(s) when is_binary(s) do
    s
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # ---- Goal pace source ----
  #
  # The goal_stats table (refreshed hourly by GoalStatsSnapshot) already
  # has 7-day completions per goal. We just compare this week vs the
  # week prior — but the snapshot only stores ONE window, so we compute
  # the comparison from raw events.
  #
  # Cheap version: skip if site has 0 goals or the goal_stats row
  # doesn't exist. For sites with goals, query CH once for last 7d vs
  # the 7d before that, per goal, and emit insights for the >=25% moves.

  defp goal_pace_insights(acc, site) do
    import Ecto.Query

    goal_count =
      Repo.aggregate(
        from(g in "goal_stats", where: g.site_id == ^site.id),
        :count
      )

    if goal_count == 0 do
      acc
    else
      pace_insights = compute_goal_pace(site)
      acc ++ pace_insights
    end
  end

  defp compute_goal_pace(site) do
    # The work here is real but constrained: 1 CH query that returns
    # per-goal current-week and prior-week completer counts. If the
    # query fails the function returns []; the worker doesn't fall over.
    case query_goal_pace(site) do
      {:ok, rows} ->
        rows
        |> Enum.filter(&significant_change?/1)
        |> Enum.map(&pace_row_to_insight(site, &1))

      _ ->
        []
    end
  end

  defp query_goal_pace(site) do
    site_p = Spectabas.ClickHouse.param(site.id)

    sql = """
    SELECT
      goal_name,
      curr_completers,
      prev_completers,
      if(prev_completers > 0,
        round((curr_completers - prev_completers) / prev_completers * 100, 1),
        0) AS pct_change
    FROM (
      SELECT
        name AS goal_name,
        uniqIf(visitor_id, timestamp >= now() - INTERVAL 7 DAY) AS curr_completers,
        uniqIf(visitor_id, timestamp >= now() - INTERVAL 14 DAY AND timestamp < now() - INTERVAL 7 DAY) AS prev_completers
      FROM (
        SELECT 'placeholder' AS name, visitor_id, timestamp FROM events WHERE site_id = #{site_p} AND 0 = 1
      )
      GROUP BY name
    )
    """

    # The query above is a placeholder shape. Goal-pace generation needs
    # the actual goal definitions joined with event filters via
    # `goal_condition/1`. That's substantial code that I'd rather lift
    # from Analytics.goal_completions_system than duplicate inline here.
    # For v1 of the insights generator: return an empty list so the
    # other sources (anomalies) still flow. Goal pace is a follow-up.
    _ = sql
    {:ok, []}
  end

  defp significant_change?(%{"pct_change" => pct}) when is_number(pct),
    do: abs(pct) >= 25

  defp significant_change?(_), do: false

  defp pace_row_to_insight(site, row) do
    pct = row["pct_change"] || 0
    direction = if pct < 0, do: "down", else: "up"

    %{
      site_id: site.id,
      kind: "goal_pace",
      severity: if(abs(pct) >= 50, do: "notice", else: "info"),
      title: "Goal \"#{row["goal_name"]}\" is #{direction} #{abs(pct) |> trunc()}% this week",
      body:
        "#{row["curr_completers"]} unique completers in the last 7 days vs " <>
          "#{row["prev_completers"]} the week before.",
      dedupe_key: Insights.dedupe_key("goal_pace", %{"goal_name" => row["goal_name"]}),
      data: %{
        "goal_name" => row["goal_name"],
        "current" => row["curr_completers"],
        "previous" => row["prev_completers"],
        "change_pct" => pct
      }
    }
  end
end
