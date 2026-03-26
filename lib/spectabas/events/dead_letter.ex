defmodule Spectabas.Events.DeadLetter do
  @moduledoc """
  Stores failed event rows into the `failed_events` table for later retry.
  """

  alias Spectabas.Repo
  alias Spectabas.Events.FailedEvent
  require Logger

  @doc """
  Enqueue a list of ClickHouse rows (maps) that failed to insert,
  along with the error reason.
  """
  def enqueue(rows, reason) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    error_str = inspect(reason, limit: 500)

    Enum.each(rows, fn row ->
      %FailedEvent{}
      |> FailedEvent.changeset(%{
        payload: Jason.encode!(row),
        error: error_str,
        attempts: 0,
        retry_after: DateTime.add(now, 300, :second),
        inserted_at: now
      })
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        {:error, err} -> Logger.error("[DeadLetter] Failed to persist: #{inspect(err)}")
      end
    end)
  end

  def enqueue(row, reason) when is_map(row), do: enqueue([row], reason)
end
