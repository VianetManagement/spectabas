defmodule Spectabas.ClickHouse do
  @moduledoc """
  Agent-based ClickHouse HTTP client with separate read/write credentials.

  All user-supplied values interpolated into queries MUST use `param/1`.
  """

  use Agent
  require Logger

  @default_opts [receive_timeout: 30_000, retry: false]

  def start_link(_opts) do
    cfg = Application.get_env(:spectabas, __MODULE__)
    write_req = build_req(cfg[:url], cfg[:username], cfg[:password], cfg[:database])
    read_req = build_req(cfg[:url], cfg[:read_username], cfg[:read_password], cfg[:database])
    Agent.start_link(fn -> %{write: write_req, read: read_req} end, name: __MODULE__)
  end

  defp build_req(url, user, pass, db) do
    Req.new(
      base_url: url,
      auth: {:basic, "#{user}:#{pass}"},
      params: [database: db],
      headers: [{"content-type", "application/x-www-form-urlencoded"}]
    )
    |> Req.merge(@default_opts)
  end

  defp write_req, do: Agent.get(__MODULE__, & &1.write)
  defp read_req, do: Agent.get(__MODULE__, & &1.read)

  @doc """
  Execute a SELECT query using the read-only credentials.
  Returns `{:ok, rows}` or `{:error, reason}`.
  """
  def query(sql, opts \\ []) do
    req = Req.merge(read_req(), params: [query: sql, default_format: "JSONEachRow"])

    case Req.get(req, opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_rows(body)}

      {:ok, %{status: s, body: b}} ->
        Logger.error("[CH:r] #{s}: #{inspect(b)}")
        {:error, b}

      {:error, r} ->
        Logger.error("[CH:r] #{inspect(r)}")
        {:error, r}
    end
  end

  @doc """
  Insert rows into a ClickHouse table using the write credentials.
  `rows` must be a non-empty list of maps.
  """
  def insert(table, rows) when is_list(rows) and rows != [] do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)

    req =
      Req.merge(write_req(),
        params: [
          query: "INSERT INTO #{sanitize_table(table)} FORMAT JSONEachRow",
          date_time_input_format: "best_effort"
        ],
        headers: [{"content-type", "text/plain"}]
      )

    case Req.post(req, body: body) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        Logger.error("[CH:w] #{s}: #{inspect(b)}")
        {:error, b}

      {:error, r} ->
        Logger.error("[CH:w] #{inspect(r)}")
        {:error, r}
    end
  end

  def insert(_table, []), do: :ok

  @doc """
  Escape a value for safe ClickHouse SQL interpolation.
  Use this for every user-supplied value in a query string.
  """
  def param(v) when is_integer(v), do: to_string(v)
  def param(v) when is_float(v), do: to_string(v)
  def param(nil), do: "NULL"

  def param(v) when is_binary(v) do
    e = v |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    "'#{e}'"
  end

  @allowed_tables ~w(events daily_stats source_stats country_stats device_stats network_stats ecommerce_events)
  defp sanitize_table(t) when t in @allowed_tables, do: t
  defp sanitize_table(t), do: raise(ArgumentError, "Unknown ClickHouse table: #{t}")

  defp parse_rows(""), do: []

  defp parse_rows(b) when is_binary(b),
    do: b |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp parse_rows(b) when is_list(b), do: b
end
