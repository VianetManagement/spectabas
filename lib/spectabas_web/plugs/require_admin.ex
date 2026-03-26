defmodule SpectabasWeb.Plugs.RequireAdmin do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    user = get_current_user(conn)

    if user && user.role == :superadmin do
      conn
    else
      Spectabas.Audit.log(:unauthorized_admin_access, %{
        user_id: user && user.id,
        path: conn.request_path
      })

      conn
      |> put_flash(:error, "You are not authorized to access this page.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  defp get_current_user(conn) do
    case conn.assigns do
      %{current_scope: %{user: user}} when not is_nil(user) -> user
      _ -> nil
    end
  end
end
