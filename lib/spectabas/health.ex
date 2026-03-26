defmodule Spectabas.Health do
  @moduledoc """
  Health checks for Postgres and ClickHouse connectivity.
  """

  alias Spectabas.{Repo, ClickHouse}

  @doc """
  Returns `:ok` if both Postgres and ClickHouse are reachable,
  or `{:error, reason}` on first failure.
  """
  def check do
    with :ok <- check_postgres(),
         :ok <- check_clickhouse() do
      :ok
    end
  end

  defp check_postgres do
    case Repo.query("SELECT 1", []) do
      {:ok, _} -> :ok
      {:error, e} -> {:error, "postgres: #{inspect(e)}"}
    end
  end

  defp check_clickhouse do
    case ClickHouse.query("SELECT 1") do
      {:ok, _} -> :ok
      {:error, e} -> {:error, "clickhouse: #{inspect(e)}"}
    end
  end
end
