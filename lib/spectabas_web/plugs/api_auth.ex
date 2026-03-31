defmodule SpectabasWeb.Plugs.ApiAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) >= 32 and byte_size(token) <= 128 ->
        case Spectabas.APIKeys.verify(token) do
          {:ok, api_key} ->
            Task.start(fn -> Spectabas.APIKeys.touch(api_key) end)

            conn
            |> assign(:api_key, api_key)
            |> assign(:current_user_id, api_key.user_id)
            |> assign(:api_scopes, api_key.scopes || [])
            |> assign(:api_site_ids, api_key.site_ids || [])

          {:error, :expired} ->
            forbidden(conn, "api key expired")

          {:error, _} ->
            unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  @doc """
  Check if the current API token has the given scope.
  """
  def has_scope?(conn, scope) do
    scope in (conn.assigns[:api_scopes] || [])
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end

  defp forbidden(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, Jason.encode!(%{error: message}))
    |> halt()
  end
end
