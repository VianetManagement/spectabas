defmodule Spectabas.Workers.ScraperCalibrationWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  require Logger

  alias Spectabas.Analytics.ScraperCalibration
  alias Spectabas.Sites

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
