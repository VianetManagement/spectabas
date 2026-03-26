defmodule SpectabasWeb.Plugs.ApiRateLimit do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    key = rate_limit_key(conn)
    {limit, window} = Application.get_env(:spectabas, :rate_limits)[:api]

    case Hammer.check_rate("api:#{key}", window, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) >= 16 ->
        String.slice(token, 0, 16)

      _ ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
