defmodule SpectabasWeb.UserLive.RegistrationTest do
  use SpectabasWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "redirects to login with disabled message", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/users/log-in", flash: flash}}} =
      live(conn, ~p"/users/register")

    assert flash["info"] =~ "disabled"
  end
end
