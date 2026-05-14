defmodule SpectabasWeb.Dashboard.CohortsLiveTest do
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
        name: "Cohorts Test Site",
        domain: "b.cohortstest.com",
        public_key: "coh_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id
      })

    conn = log_in_user(build_conn(), user)
    %{conn: conn, user: user, site: site}
  end

  describe "cohorts page rendering" do
    test "mounts and renders the create-cohort affordance for a superadmin", %{
      conn: conn,
      site: site
    } do
      {:ok, _view, html} = live(conn, ~p"/dashboard/sites/#{site.id}/cohorts")
      assert html =~ "Cohorts"
      # `New cohort` button visible because superadmin can_write?
      assert html =~ "New cohort"
      # Read-only banner is NOT shown
      refute html =~ "viewers can't create or delete cohorts"
    end

    test "prefill query params open the new-cohort form pre-populated", %{conn: conn, site: site} do
      {:ok, _view, html} =
        live(
          conn,
          ~p"/dashboard/sites/#{site.id}/cohorts?prefill_field=form_abandoned&prefill_value=contact-us&prefill_name=Abandoned: contact"
        )

      # New-cohort form open, with the prefilled name
      assert html =~ "Abandoned: contact"
      assert html =~ "form_abandoned"
      assert html =~ "contact-us"
    end
  end
end
