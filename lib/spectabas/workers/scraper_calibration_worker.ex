defmodule Spectabas.Workers.ScraperCalibrationWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Spectabas.Analytics.ScraperCalibration
  alias Spectabas.Sites

  # 600s envelope = 14 serial CH baseline queries (~3 min worst case) +
  # an Anthropic call with the v6.10.35 Stage-2 label-correlation prompt
  # (30-60s response, longer if the AI elaborates per-signal reasoning) +
  # safety margin. Matches AI.Completion @timeout (300_000) plus headroom
  # for the CH pre-work.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(600)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id}}) do
    site = Sites.get_site!(site_id)

    case ScraperCalibration.run(site) do
      {:ok, cal} ->
        Logger.notice("[ScraperCalibration] Completed for site=#{site_id}, id=#{cal.id}")

        Phoenix.PubSub.broadcast(
          Spectabas.PubSub,
          "calibration:#{site_id}",
          {:calibration_done, {:ok, cal}}
        )

        :ok

      {:error, reason} ->
        Logger.warning("[ScraperCalibration] Failed for site=#{site_id}: #{inspect(reason)}")

        Phoenix.PubSub.broadcast(
          Spectabas.PubSub,
          "calibration:#{site_id}",
          {:calibration_done, {:error, reason}}
        )

        :ok
    end
  end
end
