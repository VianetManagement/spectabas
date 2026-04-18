defmodule SpectabasWeb.API.QueryController do
  use SpectabasWeb, :controller

  require Logger

  @max_query_length 4096
  @query_timeout 30_000

  def query(conn, %{"sql" => sql}) do
    with :ok <- validate_token(conn),
         :ok <- validate_sql(sql) do
      case Spectabas.ClickHouse.query(sql, receive_timeout: @query_timeout) do
        {:ok, rows} ->
          json(conn, %{ok: true, rows: rows, count: length(rows)})

        {:error, reason} ->
          conn |> put_status(400) |> json(%{ok: false, error: inspect(reason)})
      end
    else
      {:error, status, msg} ->
        conn |> put_status(status) |> json(%{ok: false, error: msg})
    end
  end

  def query(conn, _params) do
    conn |> put_status(400) |> json(%{ok: false, error: "missing 'sql' parameter"})
  end

  defp validate_token(conn) do
    env_token = System.get_env("UTILITY_TOKEN", "")

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) >= 16 ->
        if byte_size(env_token) >= 16 and Plug.Crypto.secure_compare(token, env_token) do
          :ok
        else
          {:error, 403, "forbidden"}
        end

      _ ->
        {:error, 401, "missing or invalid Authorization header"}
    end
  end

  @blocked_keywords ~w(INSERT ALTER DROP CREATE TRUNCATE DELETE UPDATE GRANT REVOKE ATTACH DETACH RENAME OPTIMIZE SYSTEM KILL)

  defp validate_sql(sql) when byte_size(sql) > @max_query_length do
    {:error, 400, "query too long (max #{@max_query_length} chars)"}
  end

  defp validate_sql(sql) do
    normalized = sql |> String.trim() |> String.upcase()

    cond do
      not String.starts_with?(normalized, "SELECT") ->
        {:error, 400, "only SELECT queries allowed"}

      Enum.any?(@blocked_keywords -- ["SELECT"], fn kw ->
        String.contains?(normalized, kw)
      end) ->
        {:error, 400, "query contains blocked keyword"}

      true ->
        Logger.notice("[AdminQuery] #{String.slice(sql, 0, 200)}")
        :ok
    end
  end
end
