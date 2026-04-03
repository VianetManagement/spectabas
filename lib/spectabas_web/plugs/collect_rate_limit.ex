defmodule SpectabasWeb.Plugs.CollectRateLimit do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    ip = client_ip(conn)
    {limit, window} = Application.get_env(:spectabas, :rate_limits)[:collect]

    case Hammer.check_rate("collect:#{ip}", window, limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
        |> halt()
    end
  end

  defp client_ip(conn) do
    cond do
      (xff = get_req_header(conn, "x-forwarded-for")) != [] ->
        xff |> List.first() |> String.split(",") |> List.first() |> String.trim()

      (cf = get_req_header(conn, "cf-connecting-ip")) != [] ->
        cf |> List.first() |> String.trim()

      true ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
