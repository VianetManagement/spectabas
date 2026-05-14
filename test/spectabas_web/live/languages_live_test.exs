defmodule SpectabasWeb.Dashboard.LanguagesLiveTest do
  use SpectabasWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Spectabas.AccountsFixtures

  setup do
    user = user_fixture() |> set_password()

    {:ok, user} =
      user
      |> Spectabas.Accounts.User.profile_changeset(%{role: :superadmin})
      |> Spectabas.Repo.update()

    site =
      Spectabas.Repo.insert!(%Spectabas.Sites.Site{
        name: "Languages Test Site",
        domain: "b.langstest.com",
        public_key: "lang_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "languages page rendering" do
    test "renders page title and header", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/languages")
      assert html =~ "Languages"
      assert html =~ "navigator.language"
    end

    test "renders time range selector with all options", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/languages")
      assert html =~ "7 days"
      assert html =~ "30 days"
      assert html =~ "90 days"
    end

    test "time range change event works without crash", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/languages")

      for range <- ["7d", "30d", "90d"] do
        render_click(view, "change_range", %{"range" => range})
      end
    end

    test "summary cards render labels after data loads", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/languages")
      # render/1 waits for the async :load_data message to flush
      html = render(view)
      assert html =~ "Browser languages"
      assert html =~ "Page languages"
      assert html =~ "Mismatch rate"
    end

    test "all four tables render their headers after data loads", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/languages")
      html = render(view)
      assert html =~ "Top browser languages"
      assert html =~ "Top page languages"
      assert html =~ "Language × country crosstab"
      assert html =~ "Mismatches"
    end
  end
end
