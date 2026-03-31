defmodule SpectabasWeb.Plugs.ApiLogger do
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time(:millisecond)

    Plug.Conn.register_before_send(conn, fn conn ->
      # Only log if an API key was used (api_key assign exists)
      if api_key = conn.assigns[:api_key] do
        duration = System.monotonic_time(:millisecond) - start_time

        # Extract site_id from path params
        site_id = conn.path_params["site_id"]
        site_id = if site_id, do: String.to_integer(site_id), else: nil

        # Fire and forget — don't block the response
        Task.start(fn ->
          Spectabas.Repo.insert(%Spectabas.Accounts.ApiAccessLog{
            api_key_id: api_key.id,
            key_prefix: api_key.key_prefix,
            user_id: api_key.user_id,
            method: conn.method,
            path: conn.request_path,
            site_id: site_id,
            status_code: conn.status,
            ip_address: get_client_ip(conn),
            user_agent: get_user_agent(conn),
            duration_ms: duration
          })
        end)
      end

      conn
    end)
  end

  defp get_client_ip(conn) do
    cond do
      (cf = Plug.Conn.get_req_header(conn, "cf-connecting-ip")) != [] ->
        cf |> List.first() |> String.trim()

      (xff = Plug.Conn.get_req_header(conn, "x-forwarded-for")) != [] ->
        xff |> List.first() |> String.split(",") |> List.first() |> String.trim()

      true ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, 256)
      _ -> nil
    end
  end
end
