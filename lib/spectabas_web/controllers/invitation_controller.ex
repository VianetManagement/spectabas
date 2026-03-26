defmodule SpectabasWeb.InvitationController do
  use SpectabasWeb, :controller

  alias Spectabas.Accounts

  def accept(conn, %{"token" => token}) do
    case Accounts.get_valid_invitation(token) do
      {:ok, invitation} ->
        render(conn, :accept, invitation: invitation, token: token)

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This invitation has expired.")
        |> redirect(to: ~p"/")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "This invitation link is invalid.")
        |> redirect(to: ~p"/")
    end
  end

  def register(conn, %{"token" => token, "user" => user_params}) do
    client_ip = client_ip(conn)

    case check_rate_limit(client_ip) do
      :ok ->
        case Accounts.accept_invitation(token, user_params) do
          {:ok, _user} ->
            conn
            |> put_flash(:info, "Account created successfully. You may now log in.")
            |> redirect(to: ~p"/users/log-in")

          {:error, %Ecto.Changeset{} = changeset} ->
            case Accounts.get_valid_invitation(token) do
              {:ok, invitation} ->
                render(conn, :accept,
                  invitation: invitation,
                  token: token,
                  changeset: changeset
                )

              _ ->
                conn
                |> put_flash(:error, "This invitation link is invalid.")
                |> redirect(to: ~p"/")
            end

          {:error, reason} ->
            conn
            |> put_flash(:error, invitation_error_message(reason))
            |> redirect(to: ~p"/invitations/#{token}")
        end

      :rate_limited ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_flash(:error, "Too many registration attempts. Please try again later.")
        |> redirect(to: ~p"/invitations/#{token}")
    end
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      _ ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp check_rate_limit(ip) do
    {limit, window} = Application.get_env(:spectabas, :rate_limits)[:invite]

    case Hammer.check_rate("invitation:#{ip}", window, limit) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> :rate_limited
    end
  end

  defp invitation_error_message(:expired), do: "This invitation has expired."
  defp invitation_error_message(:not_found), do: "This invitation link is invalid."

  defp invitation_error_message(:already_accepted),
    do: "This invitation has already been accepted."

  defp invitation_error_message(_), do: "Something went wrong. Please try again."
end
