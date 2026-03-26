defmodule SpectabasWeb.Plugs.Require2FA do
  import Plug.Conn
  import Phoenix.Controller

  @twelve_hours 12 * 60 * 60

  def init(opts), do: opts

  def call(conn, _opts) do
    user = get_current_user(conn)

    if user && requires_2fa?(user) && !totp_verified?(conn) do
      conn
      |> redirect(to: "/auth/2fa/verify")
      |> halt()
    else
      conn
    end
  end

  defp requires_2fa?(user) do
    required_roles = Application.get_env(:spectabas, :totp_required_roles, [])
    user.totp_enabled || user.role in required_roles
  end

  defp totp_verified?(conn) do
    case get_session(conn, :totp_verified_at) do
      nil -> false
      ts when is_integer(ts) -> System.system_time(:second) - ts < @twelve_hours
      _ -> false
    end
  end

  defp get_current_user(conn) do
    case conn.assigns do
      %{current_scope: %{user: user}} when not is_nil(user) -> user
      _ -> nil
    end
  end
end
