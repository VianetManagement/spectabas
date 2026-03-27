defmodule SpectabasWeb.HealthController do
  use SpectabasWeb, :controller

  def show(conn, _params) do
    case Spectabas.Health.check() do
      :ok ->
        conn
        |> put_status(200)
        |> json(%{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(503)
        |> json(%{status: "error", reason: reason})
    end
  end

  def diag(conn, _params) do
    results = %{
      clickhouse_process: Process.whereis(Spectabas.ClickHouse) != nil,
      ingest_buffer_process: Process.whereis(Spectabas.Events.IngestBuffer) != nil,
      clickhouse_ping: test_clickhouse_ping(),
      clickhouse_tables: test_clickhouse_tables(),
      clickhouse_events_count: test_clickhouse_count(),
      sites: test_sites()
    }

    json(conn, results)
  end

  defp test_clickhouse_ping do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SELECT 1 AS ok") do
        {:ok, _} -> "ok"
        {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_clickhouse_tables do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SHOW TABLES") do
        {:ok, rows} -> Enum.map(rows, & &1["name"])
        {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_clickhouse_count do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SELECT count() AS c FROM events") do
        {:ok, [%{"c" => c}]} -> c
        {:ok, _} -> 0
        {:error, e} -> "error: #{inspect(e) |> String.slice(0, 200)}"
      end
    else
      "not_started"
    end
  end

  defp test_sites do
    Spectabas.Repo.all(Spectabas.Sites.Site)
    |> Enum.map(fn s -> %{id: s.id, domain: s.domain, public_key: s.public_key} end)
  end
end
