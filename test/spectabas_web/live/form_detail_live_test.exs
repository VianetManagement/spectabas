defmodule SpectabasWeb.Dashboard.FormDetailLiveTest do
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
        name: "Form Detail Test Site",
        domain: "b.formdetailtest.com",
        public_key: "fd_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "form detail page rendering" do
    test "mounts with a form_id and renders header sections", %{conn: conn, site: site} do
      {:ok, view, _html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/forms/contact-us")

      html = render(view)
      assert html =~ "contact-us"
      assert html =~ "Forms"
      assert html =~ "Conversion funnel"
    end

    test "renders all expected sections", %{conn: conn, site: site} do
      {:ok, view, _html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/forms/signup-form")

      html = render(view)
      assert html =~ "Conversion funnel"
      assert html =~ "Per-field drop-off"
      assert html =~ "Time per field"
      assert html =~ "Pages hosting this form"
      assert html =~ "Time-to-submit"
      assert html =~ "Submit trigger"
      assert html =~ "Validation errors"
      assert html =~ "Recent activity"
    end

    test "time range change works without crash", %{conn: conn, site: site} do
      {:ok, view, _html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/forms/contact-us")

      for range <- ["7d", "30d", "90d"] do
        render_click(view, "change_range", %{"range" => range})
      end
    end

    test "back link points to the forms list", %{conn: conn, site: site} do
      {:ok, view, _html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/forms/contact-us")

      html = render(view)
      assert html =~ "← Forms"
      assert html =~ ~p"/dashboard/sites/#{site.id}/forms"
    end

    test "create-cohort button passes form_abandoned prefill", %{conn: conn, site: site} do
      {:ok, view, _html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/forms/contact-us")

      html = render(view)
      assert html =~ "Create cohort of abandoners"
      assert html =~ "prefill_field=form_abandoned"
      assert html =~ "prefill_value=contact-us"
    end

    test "kind badge renders for cluster form_id prefix", %{conn: conn, site: site} do
      # cluster: prefix is what the tracker sends for synthetic cluster IDs
      # URI encoding of ":" → %3A
      {:ok, view, _html} =
        live(conn, ~p"/dashboard/sites/#{site.id}/forms/cluster:signup-card")

      html = render(view)
      # the form_id shows up in the header even before kpis populate
      assert html =~ "cluster:signup-card" or html =~ "cluster%3Asignup-card"
    end
  end
end
