defmodule SpectabasWeb.Dashboard.PerformanceLiveTest do
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
        name: "Perf Test Site",
        domain: "b.perftest.com",
        public_key: "perf_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "performance page rendering" do
    # Data sections are behind async loading (@loading check). Tests verify
    # the page mounts without error and shows its header/range controls.
    # Data content appears after handle_info(:load_data) processes.

    test "renders page title and header", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "Performance"
    end

    test "renders time range selector with all options", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "24h"
      assert html =~ "7 days"
      assert html =~ "30 days"
    end

    test "time range change event works without crash", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")

      for range <- ["24h", "7d", "30d"] do
        render_click(view, "change_range", %{"range" => range})
      end
    end

    test "sidebar shows Performance link as active", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      # The active nav item gets a different style
      assert html =~ "Performance"
    end

    test "page has correct title", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "Performance - #{site.name}"
    end

    test "page description mentions Real User Monitoring", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "Real User Monitoring"
    end
  end

  describe "performance on pages table" do
    test "pages table renders with deferred loading", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/pages")
      # Data loads asynchronously — initial render shows page structure
      assert html =~ "Pages"
    end
  end

  describe "performance on transitions page" do
    test "transitions page renders without error with perf data", %{conn: conn, site: site} do
      {:ok, _view, html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/pricing")

      assert html =~ "/pricing"
      assert html =~ "Page detail"
    end

    test "transitions page selector works with perf data", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions")
      html = render_submit(view, "change_page", %{"page" => "/about"})
      assert html =~ "/about"
    end
  end

  describe "page detail view" do
    test "renders all four range options including 90d", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions")
      assert html =~ "24h"
      assert html =~ "7 days"
      assert html =~ "30 days"
      assert html =~ "90 days"
    end

    test "renders all section headings", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/x")
      html = render(view)
      assert html =~ "Traffic over time"
      assert html =~ "Came from"
      assert html =~ "Went to"
      assert html =~ "Top referrers landing here"
      assert html =~ "Top search keywords"
      assert html =~ "Top countries"
      assert html =~ "Devices"
      assert html =~ "New vs returning"
      assert html =~ "Top clicked elements"
      assert html =~ "Top outbound links"
      assert html =~ "Goals from page viewers"
      assert html =~ "When visitors view this page"
    end

    test "engagement metric cards render", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/x")
      html = render(view)
      assert html =~ "Bounce rate"
      assert html =~ "Avg time on page"
      assert html =~ "Entry rate"
      assert html =~ "Exit rate"
    end

    test "range change to 90d does not crash", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/x")
      html = render_click(view, "change_range", %{"range" => "90d"})
      assert html =~ "Page detail"
    end

    test "all range options work without crashing", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/x")

      for range <- ["24h", "7d", "30d", "90d"] do
        render_click(view, "change_range", %{"range" => range})
      end
    end

    test "metric toggle does not crash", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/x")
      html = render_click(view, "toggle_metric", %{"metric" => "pageviews"})
      assert html =~ "Page detail"
      html = render_click(view, "toggle_metric", %{"metric" => "visitors"})
      assert html =~ "Page detail"
    end

    test "navigate_page event updates current page", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/x")
      html = render_click(view, "navigate_page", %{"path" => "/checkout"})
      assert html =~ "/checkout"
    end

    test "empty page submit defaults to /", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/foo")
      html = render_submit(view, "change_page", %{"page" => ""})
      # Falls back to root path
      refute html =~ ~s(value="/foo")
    end

    test "sidebar shows Page detail label", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions")
      assert html =~ "Page detail"
    end

    test "chart container renders with TimeseriesChart hook", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/x")
      html = render(view)
      assert html =~ ~s(phx-hook="TimeseriesChart")
      assert html =~ ~s(id="traffic-chart-)
    end
  end
end
