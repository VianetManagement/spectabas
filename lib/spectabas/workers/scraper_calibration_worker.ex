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
    started_at = System.monotonic_time(:millisecond)
    Logger.notice("[ScraperCalibration] Starting for site=#{site_id}")

    try do
      case ScraperCalibration.run(site) do
        {:ok, cal} ->
          elapsed = System.monotonic_time(:millisecond) - started_at

          Logger.notice(
            "[ScraperCalibration] Completed for site=#{site_id}, id=#{cal.id}, elapsed_ms=#{elapsed}"
          )

          broadcast(site_id, {:ok, cal})
          :ok

        {:error, reason} ->
          elapsed = System.monotonic_time(:millisecond) - started_at

          Logger.warning(
            "[ScraperCalibration] Failed for site=#{site_id}, elapsed_ms=#{elapsed}: #{inspect(reason)}"
          )

          broadcast(site_id, {:error, reason})
          :ok
      end
    rescue
      e ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        Logger.error(
          "[ScraperCalibration] Exception for site=#{site_id}, elapsed_ms=#{elapsed}: #{Exception.format(:error, e, __STACKTRACE__)}"
        )

        broadcast(site_id, {:error, "Crashed: #{Exception.message(e)}"})
        # Re-raise so Oban records the failure; the broadcast still
        # reaches the LiveView before the process exits.
        reraise e, __STACKTRACE__
    end
  end

  defp broadcast(site_id, payload) do
    Phoenix.PubSub.broadcast(
      Spectabas.PubSub,
      "calibration:#{site_id}",
      {:calibration_done, payload}
    )
  end
end
