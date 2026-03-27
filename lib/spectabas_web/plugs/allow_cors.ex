defmodule SpectabasWeb.Plugs.AllowCors do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = get_req_header(conn, "origin") |> List.first() || "*"

    conn =
      conn
      |> put_resp_header("access-control-allow-origin", origin)
      |> put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "content-type")
      |> put_resp_header("access-control-allow-credentials", "true")
      |> put_resp_header("vary", "Origin")

    if conn.method == "OPTIONS" do
      conn |> send_resp(204, "") |> halt()
    else
      conn
    end
  end
end
