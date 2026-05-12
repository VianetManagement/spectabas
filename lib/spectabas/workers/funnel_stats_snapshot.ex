defmodule Spectabas.Workers.FunnelStatsSnapshot do
  @moduledoc """
  Hourly snapshot of per-funnel entered / completed / conversion_rate into the
  `funnel_stats` Postgres table. The Funnels dashboard reads from this snapshot
  instead of running N parallel windowFunnel queries on every page load.

  Modes:
  - no args → enqueue a per-site job for every site that has funnels
  - `%{"site_id" => N}` → snapshot one site
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.{Analytics, Goals, Sites}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(300)

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
      if Goals.list_funnels(site) != [] do
        __MODULE__.new(%{"site_id" => site.id}) |> Oban.insert()
      end
    end)

    :ok
  end

  defp snapshot_site(site) do
    funnels = Goals.list_funnels(site)

    if funnels == [] do
      Goals.replace_funnel_stats(site, [])
      :ok
    else
      with {:ok, summaries} <- Analytics.funnel_summaries_system(site, funnels, "30d") do
        Logger.notice(
          "[FunnelStatsSnapshot] site=#{site.id} funnels=#{length(funnels)} summaries_keys=#{inspect(Map.keys(summaries))} sample=#{inspect(summaries |> Enum.take(1))}"
        )

        rows =
          Enum.map(funnels, fn funnel ->
            stats =
              Map.get(summaries, funnel.id, %{entered: 0, completed: 0, conversion_rate: 0.0})

            %{
              funnel_id: funnel.id,
              entered: stats.entered,
              completed: stats.completed,
              conversion_rate: stats.conversion_rate,
              window_days: 30
            }
          end)

        case Goals.replace_funnel_stats(site, rows) do
          {:ok, _} ->
            Logger.notice(
              "[FunnelStatsSnapshot] site=#{site.id} wrote=#{length(rows)} rows_sample=#{inspect(Enum.take(rows, 1))}"
            )

            :ok

          {:error, reason} ->
            Logger.error("[FunnelStatsSnapshot] site=#{site.id} pg_failed: #{inspect(reason)}")
            {:error, reason}
        end
      else
        {:error, reason} ->
          Logger.warning(
            "[FunnelStatsSnapshot] site=#{site.id} summaries_failed: #{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end
end
