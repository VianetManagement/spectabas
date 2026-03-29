defmodule Spectabas.Events.DeadLetter do
  @moduledoc """
  Stores failed event rows into the `failed_events` table for later retry.
  """

  alias Spectabas.Repo
  alias Spectabas.Events.FailedEvent
  require Logger

  @doc """
  Enqueue a list of ClickHouse rows (maps) that failed to insert,
  along with the error reason. Uses bulk insert (was row-by-row before).
  """
  def enqueue(rows, reason) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    error_str = inspect(reason, limit: 500)
    retry_at = DateTime.add(now, 300, :second)

    entries =
      Enum.map(rows, fn row ->
        %{
          payload: Jason.encode!(row),
          error: error_str,
          attempts: 0,
          retry_after: retry_at,
          inserted_at: now,
          updated_at: now
        }
      end)

    try do
      {count, _} = Repo.insert_all(FailedEvent, entries)
      Logger.info("[DeadLetter] Persisted #{count} failed events")
    rescue
      e -> Logger.error("[DeadLetter] Bulk persist failed: #{Exception.message(e)}")
    end
  end

  def enqueue(row, reason) when is_map(row), do: enqueue([row], reason)
end
