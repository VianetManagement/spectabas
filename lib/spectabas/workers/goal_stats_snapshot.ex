defmodule Spectabas.Workers.GoalStatsSnapshot do
  @moduledoc """
  Hourly snapshot of per-goal completions + unique completers + top sources
  into the `goal_stats` Postgres table. The Goals dashboard reads from this
  snapshot so it doesn't run N+1 ClickHouse queries on every page load.

  Modes:
  - no args → enqueue a per-site job for every site that has goals
  - `%{"site_id" => N}` → snapshot one site
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.{Analytics, Goals, Sites}

  @impl Oban.Worker
  # 20 min — load_source_attribution runs up to 4 goals concurrently, each
  # query capped at 90s. With 20 goals on the heaviest site that's ~5 batches
  # × 90s = 450s, plus the UNION-ALL completions query (up to 90s) and the
  # total_visitors query (up to 90s). Generous ceiling so a single slow goal
  # doesn't blow the whole snapshot.
  def timeout(_job), do: :timer.seconds(1200)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id}}) do
    case Sites.get_site(site_id) do
      nil -> :ok
      site -> snapshot_site(site)
    end
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    Sites.list_sites()
    |> Enum.each(fn site ->
      if Goals.list_goals(site) != [] do
        __MODULE__.new(%{"site_id" => site.id}) |> Oban.insert()
      end
    end)

    :ok
  end

  defp snapshot_site(site) do
    goals = Goals.list_goals(site)

    if goals == [] do
      Goals.replace_goal_stats(site, [])
      :ok
    else
      with {:ok, completions} <- Analytics.goal_completions_system(site, :week) do
        sources = load_source_attribution(site, goals)

        rows =
          Enum.map(completions, fn c ->
            top =
              sources
              |> Map.get(c.goal_id, [])
              |> Enum.take(3)
              |> Enum.map(fn s ->
                %{
                  "source" => to_string(s["source"] || ""),
                  "completers" => to_int(s["completers"])
                }
              end)

            %{
              goal_id: c.goal_id,
              completions: c.completions,
              unique_completers: c.unique_completers,
              conversion_rate: c.conversion_rate,
              top_sources: top,
              window_days: 7
            }
          end)

        case Goals.replace_goal_stats(site, rows) do
          {:ok, _} ->
            Logger.notice("[GoalStatsSnapshot] site=#{site.id} goals=#{length(rows)}")
            :ok

          {:error, reason} ->
            Logger.error("[GoalStatsSnapshot] site=#{site.id} pg_failed: #{inspect(reason)}")
            {:error, reason}
        end
      else
        {:error, reason} ->
          Logger.warning(
            "[GoalStatsSnapshot] site=#{site.id} completions_failed: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  defp load_source_attribution(site, goals) do
    goals
    |> Task.async_stream(
      fn goal ->
        rows =
          case Analytics.goal_source_attribution_system(site, goal, :week) do
            {:ok, rows} -> rows
            _ -> []
          end

        {goal.id, rows}
      end,
      max_concurrency: 4,
      # 100s — matches the 90s CH max_execution_time + 10s buffer. The old
      # 30s killed click-element source-attribution tasks before they could
      # finish on high-volume sites, leaving top_sources empty in goal_stats.
      timeout: 100_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, rows}}, acc -> Map.put(acc, id, rows)
      _, acc -> acc
    end)
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(_), do: 0
end
