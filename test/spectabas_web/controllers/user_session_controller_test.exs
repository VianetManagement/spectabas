defmodule SpectabasWeb.UserSessionControllerTest do
  use SpectabasWeb.ConnCase, async: true

  import Spectabas.AccountsFixtures
  import Spectabas.DataCase, only: [errors_on: 1]
  alias Spectabas.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_spectabas_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end

  describe "account lockout" do
    test "locks account after 5 failed login attempts", %{conn: conn, user: user} do
      user = set_password(user)
      email = user.email

      # Clear any existing lockout
      Hammer.delete_buckets("lockout:#{String.downcase(String.trim(email))}")

      # 5 failed attempts
      for _ <- 1..5 do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => "wrong_password1"}
        })
      end

      # 6th attempt should be locked
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => valid_user_password()}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "temporarily locked"
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "allows login after failed attempts below threshold", %{conn: conn} do
      user = user_fixture() |> set_password()
      email = user.email

      # 3 failed attempts (below 5 threshold)
      for _ <- 1..3 do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => "wrong_password1"}
        })
      end

      # Should still be able to log in
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
    end
  end

  describe "password complexity" do
    test "changeset rejects password without numbers" do
      user = user_fixture()

      changeset =
        Spectabas.Accounts.User.password_changeset(user, %{
          password: "no_numbers_here",
          password_confirmation: "no_numbers_here"
        })

      assert %{password: errors} = errors_on(changeset)
      assert "must contain at least one number" in errors
    end

    test "changeset rejects password without letters" do
      user = user_fixture()

      changeset =
        Spectabas.Accounts.User.password_changeset(user, %{
          password: "123456789012",
          password_confirmation: "123456789012"
        })

      assert %{password: errors} = errors_on(changeset)
      assert "must contain at least one letter" in errors
    end

    test "changeset accepts valid password" do
      user = user_fixture()

      changeset =
        Spectabas.Accounts.User.password_changeset(user, %{
          password: "valid_password1",
          password_confirmation: "valid_password1"
        })

      assert changeset.valid?
    end
  end

  describe "2FA verification endpoint" do
    test "GET /auth/2fa/verified sets session flag and redirects", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/auth/2fa/verified")

      assert get_session(conn, :totp_verified_at)
      assert redirected_to(conn) == ~p"/dashboard"
    end
  end
end
