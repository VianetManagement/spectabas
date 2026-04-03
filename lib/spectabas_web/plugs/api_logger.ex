defmodule SpectabasWeb.Plugs.ApiLogger do
  @behaviour Plug

  @max_body_size 4096

  def init(opts), do: opts

  def call(conn, _opts) do
    start_time = System.monotonic_time(:millisecond)

    # Capture request body before it's consumed (params are already parsed)
    request_body =
      case conn.params do
        %Plug.Conn.Unfetched{} -> nil
        params -> params |> Jason.encode!() |> String.slice(0, @max_body_size)
      end

    Plug.Conn.register_before_send(conn, fn conn ->
      if api_key = conn.assigns[:api_key] do
        duration = System.monotonic_time(:millisecond) - start_time

        site_id = conn.path_params["site_id"]
        site_id = if site_id, do: String.to_integer(site_id), else: nil

        # Capture response body (truncated)
        response_body =
          if is_binary(conn.resp_body) do
            String.slice(conn.resp_body, 0, @max_body_size)
          else
            nil
          end

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
            duration_ms: duration,
            request_body: request_body,
            response_body: response_body
          })
        end)
      end

      conn
    end)
  end

  defp get_client_ip(conn) do
    cond do
      (xff = Plug.Conn.get_req_header(conn, "x-forwarded-for")) != [] ->
        xff |> List.first() |> String.split(",") |> List.first() |> String.trim()

      (cf = Plug.Conn.get_req_header(conn, "cf-connecting-ip")) != [] ->
        cf |> List.first() |> String.trim()

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
