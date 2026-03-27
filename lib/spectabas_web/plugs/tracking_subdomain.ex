defmodule SpectabasWeb.Plugs.TrackingSubdomain do
  @moduledoc """
  For tracking subdomains (e.g. b.roommates.com), only allow /collect/* and /s.js routes.
  All other paths return a blank page. This prevents the Spectabas UI from showing
  on customer analytics subdomains.
  """

  import Plug.Conn

  @app_hosts ~w(www.spectabas.com spectabas.com localhost 127.0.0.1 www.example.com)
  @allowed_prefixes ["/c", "/s.js", "/health"]

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.host in @app_hosts or allowed_path?(conn.request_path) or conn.method == "OPTIONS" do
      conn
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "")
      |> halt()
    end
  end

  defp allowed_path?(path) do
    Enum.any?(@allowed_prefixes, &String.starts_with?(path, &1))
  end
end
