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

          {:error, _} ->
            unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
