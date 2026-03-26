defmodule SpectabasWeb.Plugs.AllowCors do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "POST, GET, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "content-type")

    if conn.method == "OPTIONS" do
      conn |> send_resp(204, "") |> halt()
    else
      conn
    end
  end
end
