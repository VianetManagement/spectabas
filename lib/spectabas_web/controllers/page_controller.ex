defmodule SpectabasWeb.PageController do
  use SpectabasWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
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
