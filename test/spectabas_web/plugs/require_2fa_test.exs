defmodule SpectabasWeb.Plugs.Require2FATest do
  use SpectabasWeb.ConnCase, async: true

  import Spectabas.AccountsFixtures

  alias SpectabasWeb.Plugs.Require2FA
  alias Spectabas.Accounts.Scope

  describe "call/2" do
    test "passes through when no user is logged in", %{conn: conn} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_user(nil))
        |> Require2FA.call([])

      refute conn.halted
    end

    test "passes through when user has no 2FA enabled", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> Require2FA.call([])

      refute conn.halted
    end

    test "redirects to verify when user has TOTP enabled but not verified", %{conn: conn} do
      user = user_fixture()

      user =
        user
        |> Ecto.Changeset.change(%{totp_enabled: true})
        |> Spectabas.Repo.update!()

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> init_test_session(%{})
        |> fetch_flash()
        |> Require2FA.call([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/2fa/verify"
    end

    test "passes through when TOTP verified recently", %{conn: conn} do
      user = user_fixture()

      user =
        user
        |> Ecto.Changeset.change(%{totp_enabled: true})
        |> Spectabas.Repo.update!()

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> init_test_session(%{totp_verified_at: System.system_time(:second)})
        |> Require2FA.call([])

      refute conn.halted
    end

    test "redirects when TOTP verification expired (>12h)", %{conn: conn} do
      user = user_fixture()

      user =
        user
        |> Ecto.Changeset.change(%{totp_enabled: true})
        |> Spectabas.Repo.update!()

      expired = System.system_time(:second) - 12 * 60 * 60 - 1

      conn =
        conn
        |> assign(:current_scope, Scope.for_user(user))
        |> init_test_session(%{totp_verified_at: expired})
        |> fetch_flash()
        |> Require2FA.call([])

      assert conn.halted
      assert redirected_to(conn) == "/auth/2fa/verify"
    end
  end
end
