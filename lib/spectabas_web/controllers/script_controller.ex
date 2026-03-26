defmodule SpectabasWeb.ScriptController do
  use SpectabasWeb, :controller

  @script_path "priv/static/assets/spectabas.js"
  @cache_control "public, max-age=86400, stale-while-revalidate=3600"

  def show(conn, _params) do
    script_path = Application.app_dir(:spectabas, @script_path)

    if File.exists?(script_path) do
      body = File.read!(script_path)

      conn
      |> put_resp_header("content-type", "application/javascript; charset=utf-8")
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, body)
    else
      send_resp(conn, 404, "")
    end
  end
end
