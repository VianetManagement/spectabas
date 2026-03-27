defmodule SpectabasWeb.PageController do
  use SpectabasWeb, :controller

  @tracking_subdomain_skip ~w(www.spectabas.com spectabas.com localhost 127.0.0.1 www.example.com)

  def home(conn, _params) do
    if conn.host in @tracking_subdomain_skip or not tracking_subdomain?(conn.host) do
      render(conn, :home)
    else
      # Tracking subdomains (e.g. b.roommates.com) show a blank page
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "")
      |> halt()
    end
  end

  defp tracking_subdomain?(host) do
    case Spectabas.Sites.get_site_by_domain(host) do
      %Spectabas.Sites.Site{} -> true
      nil -> false
    end
  end

  def pricing(conn, _params) do
    render(conn, :pricing)
  end

  def privacy(conn, _params) do
    render(conn, :privacy)
  end

  def terms(conn, _params) do
    render(conn, :terms)
  end
end
