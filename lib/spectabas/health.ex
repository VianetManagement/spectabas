defmodule Spectabas.Health do
  alias Spectabas.Repo

  def check do
    pg = check_postgres()
    ch = check_clickhouse()

    case {pg, ch} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _} -> {:error, reason}
      {_, {:error, reason}} -> {:error, reason}
    end
  end

  @doc "Minimal public status — no internal details. Postgres is required, ClickHouse is not (it starts async)."
  def status do
    buffer_size = Spectabas.Events.IngestBuffer.buffer_size()
    oban_depth = oban_queue_depth()

    cond do
      buffer_size >= 8_000 or oban_depth >= 500_000 -> "overloaded"
      check_postgres() != :ok -> "degraded"
      true -> "ok"
    end
  end

  @doc "Detailed status for authenticated admin endpoints only"
  def detailed do
    pg = check_postgres()
    ch = check_clickhouse()
    buffer_size = Spectabas.Events.IngestBuffer.buffer_size()
    oban_depth = oban_queue_depth()

    %{
      postgres: format_check(pg),
      clickhouse: format_check(ch),
      ingest_buffer: %{
        status: if(Process.whereis(Spectabas.Events.IngestBuffer), do: "running", else: "not_started"),
        size: buffer_size,
        soft_limit: 5_000,
        hard_limit: 10_000
      },
      oban: %{
        pending_jobs: oban_depth,
        overload_threshold: 500_000
      },
      overall:
        cond do
          buffer_size >= 8_000 or oban_depth >= 500_000 -> "overloaded"
          pg == :ok and ch == :ok -> "ok"
          true -> "degraded"
        end
    }
  end

  defp format_check(:ok), do: "ok"
  defp format_check({:error, reason}), do: reason

  defp check_postgres do
    case Repo.query("SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, e} -> {:error, "postgres: #{inspect(e)}"}
    end
  end

  defp check_clickhouse do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SELECT 1") do
        {:ok, _} -> :ok
        {:error, e} -> {:error, "clickhouse: #{inspect(e) |> String.slice(0, 200)}"}
      end
    else
      {:error, "clickhouse: not started"}
    end
  end

  defp oban_queue_depth do
    try do
      import Ecto.Query
      Spectabas.ObanRepo.aggregate(
        from(j in "oban_jobs", where: j.state in ["available", "scheduled", "retryable"]),
        :count
      )
    rescue
      _ -> 0
    end
  end
end
