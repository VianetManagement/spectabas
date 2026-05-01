defmodule Spectabas.Workers.DailyAnomalyDetection do
  @moduledoc """
  Once per day, recomputes the Insights anomaly set for every active site
  and writes it to `anomaly_cache`. The Insights LiveView reads from that
  cache instead of running ~15 ClickHouse comparison queries on every
  page load.

  Manual refresh from the page bypasses this worker (calls
  `AnomalyDetector.detect/2` + `AnomalyCache.put/2` directly).
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger
  import Ecto.Query

  alias Spectabas.Analytics.{AnomalyCache, AnomalyDetector}
  alias Spectabas.{Repo, Sites}

  # ClickHouse maintenance budget per CLAUDE.md.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(_job) do
    sites = Sites.list_sites() |> Enum.filter(& &1.active)

    Logger.notice(
      "[DailyAnomalyDetection] Refreshing anomaly cache for #{length(sites)} active site(s)"
    )

    Enum.each(sites, fn site ->
      try do
        case find_site_admin(site) do
          nil ->
            Logger.warning("[DailyAnomalyDetection] No admin for site #{site.id}, skipping")
            :ok

          user ->
            case AnomalyDetector.detect(site, user) do
              {:ok, anomalies} ->
                AnomalyCache.put(site.id, anomalies)

              {:error, reason} ->
                Logger.warning(
                  "[DailyAnomalyDetection] detect failed site=#{site.id}: #{inspect(reason)}"
                )
            end
        end
      rescue
        e ->
          Logger.warning(
            "[DailyAnomalyDetection] crashed site=#{site.id}: #{Exception.message(e)}"
          )
      end
    end)

    :ok
  end

  # Same pattern as Workers.AIWeeklyEmail — pick any admin/superadmin on the
  # site's account to satisfy AnomalyDetector.detect/2's authorize check.
  defp find_site_admin(site) do
    Repo.one(
      from(u in Spectabas.Accounts.User,
        where: u.account_id == ^site.account_id and u.role in [:superadmin, :platform_admin],
        limit: 1
      )
    )
  end
end
