defmodule Spectabas.Health do
  alias Spectabas.Repo

  def check do
    with :ok <- check_postgres() do
      case check_clickhouse() do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end
  end

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
        {:error, e} -> {:error, "clickhouse: #{inspect(e)}"}
      end
    else
      {:error, "clickhouse: not started"}
    end
  end
end
