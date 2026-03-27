defmodule SpectabasWeb.PageController do
  use SpectabasWeb, :controller

  def home(conn, _params), do: render(conn, :home)
  def pricing(conn, _params), do: render(conn, :pricing)
  def privacy(conn, _params), do: render(conn, :privacy)
  def terms(conn, _params), do: render(conn, :terms)
end
