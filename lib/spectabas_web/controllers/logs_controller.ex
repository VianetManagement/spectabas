defmodule SpectabasWeb.LogsController do
  @moduledoc """
  Server-log ingest endpoint. POST /c/logs with:

      Authorization: Bearer <site.logs_token>
      Content-Type: application/json

  Body shapes accepted (both common):

      # 1. Render Log Streams format — array of entries
      [
        {"timestamp": "...", "level": "info", "message": "..."},
        ...
      ]

      # 2. Wrapped envelope
      {"logs": [{...}, {...}]}

  Each entry is parsed/normalized by `Spectabas.Logs.parse_and_normalize/2`
  and handed to the LogsIngestBuffer for async flush.

  ## Returns

  - 200 with `{"accepted": N}` on success
  - 401 if no/invalid bearer token
  - 403 if site has `logs_enabled = false`
  - 413 if body is too large (max 5MB)
  - 503 if the ingest buffer is at the soft limit (back off)
  """
  use SpectabasWeb, :controller

  alias Spectabas.Logs
  alias Spectabas.Logs.IngestBuffer

  require Logger

  @max_body_bytes 5_000_000
  @max_lines 5_000

  def create(conn, _params) do
    with {:ok, token} <- bearer_token(conn),
         %{logs_enabled: true} = site <- Logs.site_by_token(token),
         {:ok, entries} <- extract_entries(conn),
         :ok <- validate_size(entries) do
      if IngestBuffer.full?() do
        send_resp(conn, 503, ~s({"error":"overloaded","retry_after_ms":1000}))
      else
        rows =
          entries
          |> Enum.map(&Logs.parse_and_normalize(&1, site.id))
          |> Enum.reject(&is_nil/1)

        IngestBuffer.push_batch(rows)

        json(conn, %{accepted: length(rows)})
      end
    else
      :no_token ->
        send_resp(conn, 401, ~s({"error":"missing_bearer_token"}))

      :invalid_token ->
        send_resp(conn, 401, ~s({"error":"invalid_token"}))

      %{logs_enabled: false} ->
        send_resp(conn, 403, ~s({"error":"logs_not_enabled_for_site"}))

      {:error, :too_large} ->
        send_resp(conn, 413, ~s({"error":"body_too_large"}))

      {:error, :too_many_lines} ->
        send_resp(conn, 413, ~s({"error":"too_many_lines","max":#{@max_lines}}))

      {:error, :invalid_body} ->
        send_resp(conn, 400, ~s({"error":"invalid_body"}))

      nil ->
        send_resp(conn, 401, ~s({"error":"invalid_token"}))

      _other ->
        send_resp(conn, 400, ~s({"error":"unknown"}))
    end
  end

  def options(conn, _params) do
    conn
    |> put_resp_header("access-control-allow-methods", "POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "authorization, content-type")
    |> put_resp_header("access-control-max-age", "86400")
    |> send_resp(204, "")
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> tok] when byte_size(tok) > 0 -> {:ok, tok}
      ["bearer " <> tok] when byte_size(tok) > 0 -> {:ok, tok}
      _ -> :no_token
    end
  end

  defp extract_entries(conn) do
    case conn.body_params do
      list when is_list(list) -> {:ok, list}
      %{"logs" => list} when is_list(list) -> {:ok, list}
      %{"records" => list} when is_list(list) -> {:ok, list}
      %{} -> {:error, :invalid_body}
      _ -> {:error, :invalid_body}
    end
  end

  defp validate_size(entries) do
    cond do
      length(entries) > @max_lines -> {:error, :too_many_lines}
      true -> :ok
    end
  end

  # Used by router pipeline to set max body size for this endpoint.
  def max_body_bytes, do: @max_body_bytes
end
