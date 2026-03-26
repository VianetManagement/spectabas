defmodule SpectabasWeb.Plugs.SiteResolver do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case Spectabas.Sites.DomainCache.lookup(conn.host) do
      {:ok, site} ->
        conn
        |> assign(:site, site)
        |> assign(:site_id, site.id)

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "site_not_found"}))
        |> halt()
    end
  end
end
