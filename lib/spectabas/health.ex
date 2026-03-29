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

  @doc "Detailed status for JSON health endpoint"
  def detailed do
    pg = check_postgres()
    ch = check_clickhouse()
    buffer = check_buffer()

    %{
      postgres: format_check(pg),
      clickhouse: format_check(ch),
      ingest_buffer: buffer,
      overall: if(pg == :ok and ch == :ok, do: "ok", else: "degraded")
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

  defp check_buffer do
    if Process.whereis(Spectabas.Events.IngestBuffer) do
      "running"
    else
      "not_started"
    end
  end
end
