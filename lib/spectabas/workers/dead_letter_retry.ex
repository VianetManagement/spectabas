defmodule Spectabas.Workers.DeadLetterRetry do
  @moduledoc """
  Retries failed ClickHouse inserts from the failed_events table.
  Fetches rows where attempts < 10 and retry_after <= now, attempts
  to insert them into ClickHouse, and either deletes on success or
  increments attempts on failure.
  """

  use Oban.Worker, queue: :default, max_attempts: 10

  import Ecto.Query, warn: false

  alias Spectabas.{Repo, ClickHouse}
  alias Spectabas.Events.FailedEvent

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(120)

  @max_attempts 10
  @batch_size 500
  @retry_delay_minutes 5

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    failed_events =
      from(f in FailedEvent,
        where: f.attempts < ^@max_attempts,
        where: is_nil(f.retry_after) or f.retry_after <= ^now,
        limit: ^@batch_size,
        order_by: [asc: f.inserted_at]
      )
      |> Repo.all()

    if failed_events == [] do
      :ok
    else
      rows =
        Enum.map(failed_events, fn fe ->
          Jason.decode!(fe.payload)
        end)

      case ClickHouse.insert("events", rows) do
        :ok ->
          ids = Enum.map(failed_events, & &1.id)
          Repo.delete_all(from(f in FailedEvent, where: f.id in ^ids))
          :ok

        {:error, reason} ->
          retry_after = DateTime.add(now, @retry_delay_minutes * 60, :second)

          Enum.each(failed_events, fn fe ->
            fe
            |> FailedEvent.changeset(%{
              attempts: (fe.attempts || 0) + 1,
              retry_after: retry_after,
              error: inspect(reason)
            })
            |> Repo.update()
          end)

          :ok
      end
    end
  end
end
