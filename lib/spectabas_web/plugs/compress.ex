defmodule SpectabasWeb.Plugs.Compress do
  @moduledoc """
  Gzip-compresses dynamic responses when the client supports it.
  Static files are handled by Plug.Static's gzip option; this plug
  covers HTML, JSON, and other dynamic content.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &compress_response/1)
  end

  defp compress_response(conn) do
    accept_encoding =
      Plug.Conn.get_req_header(conn, "accept-encoding")
      |> List.first("")

    cond do
      # Skip if already encoded (e.g., by Plug.Static)
      Plug.Conn.get_resp_header(conn, "content-encoding") != [] ->
        conn

      # Skip non-compressible or tiny responses
      conn.resp_body == nil ->
        conn

      not String.contains?(accept_encoding, "gzip") ->
        conn

      not compressible?(conn) ->
        conn

      byte_size(to_string(conn.resp_body)) < 860 ->
        conn

      true ->
        compressed = :zlib.gzip(conn.resp_body)

        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.put_resp_header("vary", "Accept-Encoding")
        |> Map.put(:resp_body, compressed)
    end
  end

  defp compressible?(conn) do
    content_type =
      Plug.Conn.get_resp_header(conn, "content-type")
      |> List.first("")

    String.contains?(content_type, "text/html") or
      String.contains?(content_type, "application/json") or
      String.contains?(content_type, "text/javascript") or
      String.contains?(content_type, "text/css") or
      String.contains?(content_type, "text/plain") or
      String.contains?(content_type, "application/xml") or
      String.contains?(content_type, "image/svg+xml")
  end
end
