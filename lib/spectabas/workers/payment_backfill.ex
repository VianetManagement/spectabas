defmodule Spectabas.Workers.PaymentBackfill do
  @moduledoc """
  Oban worker for backfilling payment data (Stripe/Braintree).
  Runs on the ad_sync queue using the ObanRepo pool, isolating it
  from the web connection pool.
  """

  use Oban.Worker, queue: :ad_sync, max_attempts: 1, unique: [period: 300]

  require Logger

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.SyncLog

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => integration_id, "num_days" => num_days}}) do
    integration =
      AdIntegrations.get!(integration_id)
      |> Spectabas.Repo.preload(:site)

    start = System.monotonic_time(:millisecond)
    today = Date.utc_today()

    SyncLog.log(
      integration,
      "backfill_start",
      "ok",
      "Backfill started for last #{num_days} days (Oban)"
    )

    result =
      Enum.reduce_while(0..num_days, 0, fn offset, synced_days ->
        date = Date.add(today, -offset)

        # Brief pause between days to avoid connection exhaustion
        if offset > 0, do: Process.sleep(500)

        day_result =
          case integration.platform do
            "stripe" ->
              Spectabas.AdIntegrations.Platforms.StripePlatform.sync_charges(
                integration.site,
                integration,
                date
              )

            "braintree" ->
              Spectabas.AdIntegrations.Platforms.BraintreePlatform.sync_transactions(
                integration.site,
                integration,
                date
              )

            _ ->
              :noop
          end

        case day_result do
          {:error, reason}
          when reason in [
                 "Braintree credentials not configured",
                 "Invalid Braintree credentials"
               ] ->
            Logger.warning("[Backfill] Aborting — #{reason}")
            ms = System.monotonic_time(:millisecond) - start
            SyncLog.log(integration, "backfill", "error", reason, duration_ms: ms)
            {:halt, {:error, reason}}

          _ ->
            {:cont, synced_days + 1}
        end
      end)

    case result do
      {:error, _} ->
        :ok

      days_done ->
        ms = System.monotonic_time(:millisecond) - start

        SyncLog.log(integration, "backfill", "ok", "Backfill completed: #{days_done} days synced",
          duration_ms: ms
        )
    end

    :ok
  end
end
