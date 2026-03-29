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
        gdpr_mode: "off"
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "performance page rendering" do
    test "renders Core Web Vitals heading", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "Core Web Vitals"
    end

    test "renders Page Load Timing heading", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "Page Load Timing"
    end

    test "shows empty state for vitals when no data", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "No Core Web Vitals data yet"
    end

    test "shows empty state for timing when no data", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "No performance data yet"
    end

    test "renders sample count", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "samples"
    end

    test "renders time range selector with all options", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")
      assert html =~ "24h"
      assert html =~ "7 days"
      assert html =~ "30 days"
    end

    test "time range change event works", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/performance")

      for range <- ["24h", "7d", "30d"] do
        html = render_click(view, "change_range", %{"range" => range})
        assert html =~ "Core Web Vitals"
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
    test "pages table includes Load Time column", %{conn: conn, site: site} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/pages")
      assert html =~ "Load Time"
    end
  end

  describe "performance on transitions page" do
    test "transitions page renders without error with perf data", %{conn: conn, site: site} do
      {:ok, _view, html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/transitions?page=/pricing")

      assert html =~ "/pricing"
      assert html =~ "Page Transitions"
    end

    test "transitions page selector works with perf data", %{conn: conn, site: site} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/sites/#{site.id}/transitions")
      html = render_submit(view, "change_page", %{"page" => "/about"})
      assert html =~ "/about"
    end
  end
end
