defmodule SpectabasWeb.UserSessionController do
  use SpectabasWeb, :controller

  alias Spectabas.Accounts
  alias SpectabasWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    ip = login_ip(conn)
    normalized_email = String.downcase(String.trim(email))

    {limit, window} = Application.get_env(:spectabas, :rate_limits)[:login]

    # Layer 1: IP-based rate limit
    case Hammer.check_rate("login:#{ip}", window, limit) do
      {:deny, _} ->
        conn
        |> put_flash(:error, "Too many login attempts. Please try again later.")
        |> redirect(to: ~p"/users/log-in")

      {:allow, _} ->
        # Layer 2: Per-email lockout (5 failures = 15 min lockout)
        case Hammer.check_rate("lockout:#{normalized_email}", 900_000, 5) do
          {:deny, _} ->
            conn
            |> put_flash(:error, "Account temporarily locked due to too many failed attempts. Try again in 15 minutes.")
            |> redirect(to: ~p"/users/log-in")

          {:allow, _} ->
            if user = Accounts.get_user_by_email_and_password(email, password) do
              # Reset lockout counter on successful login
              Hammer.delete_buckets("lockout:#{normalized_email}")

              conn
              |> put_flash(:info, info)
              |> UserAuth.log_in_user(user, user_params)
            else
              # Check if this failure triggers a lockout
              case Hammer.check_rate("lockout:#{normalized_email}", 900_000, 5) do
                {:deny, _} ->
                  Spectabas.Audit.log("user.account_locked", %{
                    email: normalized_email,
                    ip: ip,
                    reason: "5 failed login attempts"
                  })

                _ ->
                  :ok
              end

              conn
              |> put_flash(:error, "Invalid email or password")
              |> put_flash(:email, String.slice(email, 0, 160))
              |> redirect(to: ~p"/users/log-in")
            end
        end
    end
  end

  defp login_ip(conn) do
    case Plug.Conn.get_req_header(conn, "cf-connecting-ip") do
      [ip | _] ->
        String.trim(ip)

      [] ->
        case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
          [xff | _] -> xff |> String.split(",") |> List.first() |> String.trim()
          [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
        end
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
