defmodule SpectabasWeb.DashboardPagesTest do
  use SpectabasWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Spectabas.AccountsFixtures

  setup do
    user = user_fixture() |> set_password()
    # Make user an admin so they can access all pages
    {:ok, user} =
      user
      |> Spectabas.Accounts.User.profile_changeset(%{role: :superadmin})
      |> Spectabas.Repo.update()

    site =
      Spectabas.Repo.insert!(%Spectabas.Sites.Site{
        name: "Test Site",
        domain: "b.test.com",
        public_key: "test_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off"
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "dashboard pages render without errors" do
    test "main dashboard", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}")
      assert html =~ site.name
    end

    test "pages", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/pages")
      assert html =~ "Top Pages"
    end

    test "sources", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/sources")
      assert html =~ "Sources"
    end

    test "geography", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/geo")
      assert html =~ "Geography"
    end

    test "devices", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/devices")
      assert html =~ "Devices"
    end

    test "entry/exit pages", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/entry-exit")
      assert html =~ "Entry"
    end

    test "visitor map", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/map")
      assert html =~ "Visitor Map"
    end

    test "visitor log", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/visitor-log")
      assert html =~ "Visitor Log"
    end

    test "transitions", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions")
      assert html =~ "Page Transitions"
    end

    test "attribution", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/attribution")
      assert html =~ "Attribution"
    end

    test "site search", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/search")
      assert html =~ "Site Search"
    end

    test "cohort retention", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/cohort")
      assert html =~ "Cohort Retention"
    end

    test "network", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/network")
      assert html =~ "Network"
    end

    test "realtime", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/realtime")
      assert html =~ "Realtime"
    end

    test "settings", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/settings")
      assert html =~ "Settings"
    end

    test "goals", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/goals")
      assert html =~ "Goals"
    end

    test "funnels", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/funnels")
      assert html =~ "Funnels"
    end

    test "ecommerce", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/ecommerce")
      assert html =~ "Ecommerce"
    end

    test "campaigns", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/campaigns")
      assert html =~ "Campaigns"
    end

    test "reports", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/reports")
      assert html =~ "Reports"
    end

    test "exports", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/exports")
      assert html =~ "Exports"
    end

    test "visitors list", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/visitors")
      assert html =~ "Visitors"
    end

    test "performance", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "Performance"
      assert html =~ "Core Web Vitals"
    end
  end

  describe "sidebar is present on all pages" do
    test "main dashboard has sidebar", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}")
      assert html =~ "All Sites"
      assert html =~ "Behavior"
      assert html =~ "Acquisition"
      assert html =~ "Audience"
    end

    test "sub-pages have sidebar", %{conn: conn, site: site} do
      pages =
        ~w(pages sources geo devices network entry-exit map visitor-log transitions attribution search cohort campaigns goals funnels ecommerce reports exports settings performance)

      for page <- pages do
        {:ok, _view, html} = live(conn, "/dashboard/sites/#{site.id}/#{page}")
        assert html =~ "All Sites", "Sidebar missing on /#{page}"
      end
    end
  end

  describe "page descriptions are present" do
    test "dashboard has description", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}")
      assert html =~ "Overview of your site"
    end

    test "pages has description", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/pages")
      assert html =~ "Top pages ranked"
    end
  end

  describe "admin pages render without errors" do
    test "admin dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
    end

    test "admin users", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/users")
      assert html =~ "Users"
    end

    test "admin sites", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/sites")
      assert html =~ "Sites"
    end

    test "admin audit", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/audit")
      assert html =~ "Audit"
    end
  end

  describe "dashboard index" do
    test "shows sites and add button for admins", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ site.name
      assert html =~ "Add Site"
    end
  end

  describe "performance page" do
    test "renders core web vitals section", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "Core Web Vitals"
      assert html =~ "Page Load Timing"
    end

    test "renders time range buttons", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "24h"
      assert html =~ "7 days"
      assert html =~ "30 days"
    end

    test "handles time range change", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      html = render_click(view, "change_range", %{"range" => "30d"})
      assert html =~ "30 days"
    end

    test "shows empty state when no data", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "No Core Web Vitals data yet" || html =~ "No performance data yet"
    end
  end

  describe "pages table" do
    test "renders load time column header", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/pages")
      assert html =~ "Load Time"
    end
  end

  describe "transitions page" do
    test "renders page selector", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions")
      assert html =~ "Page path"
      assert html =~ "Analyze"
    end

    test "handles page navigation", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions")
      html = render_submit(view, "change_page", %{"page" => "/about"})
      assert html =~ "/about"
    end
  end

  describe "docs page" do
    test "renders documentation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/docs")
      assert html =~ "Documentation"
      assert html =~ "Quick Start Guide"
    end

    test "renders JavaScript API section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/docs")
      assert html =~ "JavaScript API"
      assert html =~ "Spectabas.track"
    end

    test "renders Performance RUM section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/docs")
      assert html =~ "Performance (RUM)"
      assert html =~ "Core Web Vitals"
    end

    test "search filters articles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/docs")
      html = render_keyup(view, "search", %{"q" => "ecommerce"})
      assert html =~ "Ecommerce"
    end
  end
end
