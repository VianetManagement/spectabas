defmodule SpectabasWeb.UserLive.ApiKeySettingsTest do
  use SpectabasWeb.ConnCase, async: true

  alias Spectabas.{Repo, APIKeys}
  alias Spectabas.Accounts.APIKey
  import Phoenix.LiveViewTest
  import Spectabas.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture() |> set_password()

    {:ok, user} =
      user
      |> Spectabas.Accounts.User.profile_changeset(%{role: :admin})
      |> Repo.update()

    site =
      Repo.insert!(%Spectabas.Sites.Site{
        name: "API Key Test Site",
        domain: "b.apikey-test.com",
        public_key: "apikey_test_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off"
      })

    conn = log_in_user(conn, user)
    %{conn: conn, user: user, site: site}
  end

  describe "API key section on settings page" do
    test "renders API key section", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "API Keys"
      assert html =~ "sab_live_"
    end

    test "shows create form with scopes and options", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html = render_click(lv, "toggle_api_form")

      assert html =~ "Permissions"
      assert html =~ "read:stats"
      assert html =~ "read:visitors"
      assert html =~ "write:events"
      assert html =~ "write:identify"
      assert html =~ "admin:sites"
      assert html =~ "Expiry Date"
      assert html =~ "Restrict to Sites"
    end

    test "creates API key with default scopes", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      render_click(lv, "toggle_api_form")

      html =
        lv
        |> form("form[phx-submit=create_api_key]", %{
          "name" => "Test Key",
          "scopes" => ["read:stats", "read:visitors"]
        })
        |> render_submit()

      assert html =~ "API key created"
      assert html =~ "sab_live_"
    end

    test "creates API key with site restrictions", %{conn: conn, site: site} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      render_click(lv, "toggle_api_form")

      html =
        lv
        |> form("form[phx-submit=create_api_key]", %{
          "name" => "Site-Restricted Key",
          "scopes" => ["read:stats"],
          "site_ids" => [to_string(site.id)]
        })
        |> render_submit()

      assert html =~ "API key created"
      assert html =~ "1 site(s) only"
    end

    test "creates API key with expiry date", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      render_click(lv, "toggle_api_form")

      expiry = Date.add(Date.utc_today(), 30) |> Date.to_iso8601()

      html =
        lv
        |> form("form[phx-submit=create_api_key]", %{
          "name" => "Expiring Key",
          "scopes" => ["read:stats"],
          "expires_at" => expiry
        })
        |> render_submit()

      assert html =~ "API key created"
      assert html =~ "Expires"
    end

    test "displays scope badges on existing keys", %{conn: conn, user: user} do
      {:ok, _key, _} =
        APIKeys.generate(user, "Scoped Key", scopes: ["read:stats", "write:events"])

      {:ok, _lv, html} = live(conn, ~p"/users/settings")

      assert html =~ "read:stats"
      assert html =~ "write:events"
      assert html =~ "Scoped Key"
    end

    test "displays expired badge for expired keys", %{conn: conn, user: user} do
      expired = DateTime.add(DateTime.utc_now(), -86400, :second)

      {:ok, _key, _} =
        APIKeys.generate(user, "Old Key", expires_at: expired)

      {:ok, _lv, html} = live(conn, ~p"/users/settings")

      assert html =~ "Expired"
    end

    test "revokes an API key", %{conn: conn, user: user} do
      {:ok, _key, api_key} = APIKeys.generate(user, "KeyToRevoke")

      {:ok, lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "KeyToRevoke"

      html = render_click(lv, "revoke_api_key", %{"id" => to_string(api_key.id)})
      assert html =~ "API key revoked"
    end

    test "shows 'All sites' when no site restriction", %{conn: conn, user: user} do
      {:ok, _key, _} = APIKeys.generate(user, "Unrestricted Key")

      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "All sites"
    end
  end
end
