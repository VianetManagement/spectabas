defmodule Spectabas.Workers.DeadLetterMonitor do
  @moduledoc """
  Monitors the dead letter queue size and logs warnings when it grows.
  Runs via Oban cron every 10 minutes.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query
  require Logger

  alias Spectabas.Repo
  alias Spectabas.Events.FailedEvent

  @warning_threshold 100

  @impl Oban.Worker
  def perform(_job) do
    count = Repo.aggregate(from(f in FailedEvent), :count)

    if count > @warning_threshold do
      Logger.error(
        "[DeadLetterMonitor] #{count} events in dead letter queue (threshold: #{@warning_threshold}). ClickHouse may be down."
      )
    end

    :ok
  end
end
