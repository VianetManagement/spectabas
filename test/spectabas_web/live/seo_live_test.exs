defmodule SpectabasWeb.Dashboard.SEOLiveTest do
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
        name: "SEO Test Site",
        domain: "b.seotest.com",
        public_key: "seo_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id,
        seo_crawl_budget: 500
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "seo page rendering" do
    test "mounts and renders headers", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/seo")
      assert html =~ "SEO audit"
      assert html =~ "Audited pages"
      assert html =~ "Weekly budget"
    end

    test "shows headless-not-configured warning when PLAYWRIGHT_URL is absent", %{
      conn: conn,
      site: site
    } do
      Application.put_env(:spectabas, :playwright_url, nil)
      System.delete_env("PLAYWRIGHT_URL")

      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/seo")
      assert html =~ "Headless service not configured"
    end

    test "shows audit-form for write-able users", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/seo")
      assert html =~ "Audit this URL"
      assert html =~ "Audit top pages"
      refute html =~ "Viewers can't trigger SEO audits"
    end

    test "rejects non-http audit URL submission", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/seo")
      render_change(view, "update_audit_url", %{"audit_url_input" => "not-a-url"})
      html = render_submit(view, "audit_url", %{})
      assert html =~ "URL must start with"
    end

    test "sort selector updates assigns", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/seo")
      render_change(view, "change_sort", %{"sort" => "recent"})
      html = render(view)
      assert html =~ "Most recent audit"
    end
  end
end
