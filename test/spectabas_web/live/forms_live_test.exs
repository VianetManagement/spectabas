defmodule SpectabasWeb.Dashboard.FormsLiveTest do
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
        name: "Forms Test Site",
        domain: "b.formstest.com",
        public_key: "forms_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "forms page rendering" do
    test "renders page title and header", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/forms")
      assert html =~ "Forms"
      assert html =~ "Auto-tracked"
    end

    test "renders time range selector with all options", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/forms")
      assert html =~ "7 days"
      assert html =~ "30 days"
      assert html =~ "90 days"
    end

    test "time range change event works without crash", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/forms")

      for range <- ["7d", "30d", "90d"] do
        render_click(view, "change_range", %{"range" => range})
      end
    end

    test "select_form event opens per-field section without crashing", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/forms")

      html =
        render_click(view, "select_form", %{
          "form_id" => "contact",
          "form_name" => "Contact form"
        })

      assert html =~ "Per-field drop-off"
      assert html =~ "Contact form"
    end

    test "clear_form event closes per-field section", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/forms")

      render_click(view, "select_form", %{
        "form_id" => "contact",
        "form_name" => "Contact form"
      })

      html = render_click(view, "clear_form", %{})

      refute html =~ "Per-field drop-off"
    end
  end
end
