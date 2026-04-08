defmodule SpectabasWeb.Plugs.Require2FA do
  @moduledoc """
  Ensures users with 2FA enabled have verified their TOTP this session.
  Also enforces account-level MFA requirement — redirects to setup if needed.
  """

  import Plug.Conn
  import Phoenix.Controller

  @twelve_hours 12 * 60 * 60

  def init(opts), do: opts

  def call(conn, _opts) do
    user = get_current_user(conn)

    cond do
      # No user — other plugs will handle auth
      is_nil(user) ->
        conn

      # User has 2FA enabled but hasn't verified this session → verify
      user.totp_enabled && !totp_verified?(conn) ->
        conn
        |> put_session(:user_return_to, conn.request_path)
        |> redirect(to: "/auth/2fa/verify")
        |> halt()

      # Account requires MFA but user hasn't set it up → setup
      account_requires_mfa?(user) && !user.totp_enabled && !has_webauthn?(user) ->
        conn
        |> put_flash(
          :error,
          "Your organization requires two-factor authentication. Please set it up to continue."
        )
        |> put_session(:user_return_to, conn.request_path)
        |> redirect(to: "/auth/2fa/setup")
        |> halt()

      true ->
        conn
    end
  end

  defp totp_verified?(conn) do
    case get_session(conn, :totp_verified_at) do
      nil -> false
      ts when is_integer(ts) -> System.system_time(:second) - ts < @twelve_hours
      _ -> false
    end
  end

  defp account_requires_mfa?(user) do
    if user.account_id do
      case Spectabas.Repo.get(Spectabas.Accounts.Account, user.account_id) do
        %{require_mfa: true} -> true
        _ -> false
      end
    else
      # platform_admin (no account) — no account-level requirement
      false
    end
  end

  defp has_webauthn?(user) do
    import Ecto.Query

    Spectabas.Repo.exists?(
      from(w in Spectabas.Accounts.WebauthnCredential, where: w.user_id == ^user.id)
    )
  end

  defp get_current_user(conn) do
    case conn.assigns do
      %{current_scope: %{user: user}} when not is_nil(user) -> user
      _ -> nil
    end
  end
end
