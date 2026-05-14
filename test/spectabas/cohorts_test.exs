defmodule Spectabas.CohortsTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.{Cohorts, Repo, Sites}
  alias Spectabas.Cohorts.Cohort

  defp build_site! do
    Repo.insert!(%Sites.Site{
      name: "Test Site #{System.unique_integer([:positive])}",
      domain: "b.t-#{System.unique_integer([:positive])}.com",
      public_key: "k_#{System.unique_integer([:positive])}",
      active: true,
      gdpr_mode: "off",
      account_id: Spectabas.AccountsFixtures.test_account().id
    })
  end

  defp build_user! do
    Spectabas.AccountsFixtures.user_fixture()
  end

  describe "create/3" do
    test "creates a cohort with a filter list" do
      site = build_site!()
      user = build_user!()

      assert {:ok, cohort} =
               Cohorts.create(site.id, user.id, %{
                 "name" => "Mobile from Reddit",
                 "filters" => [
                   %{"field" => "device_type", "op" => "is", "value" => "smartphone"},
                   %{"field" => "referrer_domain", "op" => "is", "value" => "reddit.com"}
                 ]
               })

      assert cohort.name == "Mobile from Reddit"
      assert Cohort.filters_list(cohort) |> length() == 2
    end

    test "rejects invalid filter fields" do
      site = build_site!()
      user = build_user!()

      assert {:error, changeset} =
               Cohorts.create(site.id, user.id, %{
                 "name" => "Bogus",
                 "filters" => [%{"field" => "not_a_real_field", "op" => "is", "value" => "x"}]
               })

      refute changeset.valid?
    end

    test "requires a name" do
      site = build_site!()
      user = build_user!()

      assert {:error, changeset} = Cohorts.create(site.id, user.id, %{"filters" => []})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "list_for_user/2" do
    test "returns user's private cohorts + all site-visibility cohorts" do
      site = build_site!()
      user_a = build_user!()
      user_b = build_user!()

      {:ok, _priv_a} =
        Cohorts.create(site.id, user_a.id, %{
          "name" => "User A private",
          "visibility" => "private"
        })

      {:ok, _priv_b} =
        Cohorts.create(site.id, user_b.id, %{
          "name" => "User B private",
          "visibility" => "private"
        })

      {:ok, _shared} =
        Cohorts.create(site.id, user_a.id, %{"name" => "Team shared", "visibility" => "site"})

      a_list = Cohorts.list_for_user(site.id, user_a.id) |> Enum.map(& &1.name) |> Enum.sort()
      b_list = Cohorts.list_for_user(site.id, user_b.id) |> Enum.map(& &1.name) |> Enum.sort()

      assert a_list == ["Team shared", "User A private"]
      assert b_list == ["Team shared", "User B private"]
    end
  end

  describe "to_sql/1" do
    test "produces an empty string for a cohort with no filters" do
      site = build_site!()
      user = build_user!()
      {:ok, c} = Cohorts.create(site.id, user.id, %{"name" => "Everyone"})
      assert Cohorts.to_sql(c) == ""
    end

    test "produces a CH WHERE fragment for a cohort with filters" do
      site = build_site!()
      user = build_user!()

      {:ok, c} =
        Cohorts.create(site.id, user.id, %{
          "name" => "US smartphones",
          "filters" => [
            %{"field" => "ip_country", "op" => "is", "value" => "US"},
            %{"field" => "device_type", "op" => "is", "value" => "smartphone"}
          ]
        })

      sql = Cohorts.to_sql(c)
      assert sql =~ "ip_country"
      assert sql =~ "device_type"
    end

    test "accepts new CH-direct fields added v6.10.34" do
      site = build_site!()
      user = build_user!()

      for field <-
            ~w(ip_is_bot ip_is_datacenter ip_is_vpn click_id_type utm_term utm_content ip_continent_name) do
        {:ok, c} =
          Cohorts.create(site.id, user.id, %{
            "name" => "test_#{field}_#{System.unique_integer([:positive])}",
            "filters" => [%{"field" => field, "op" => "is", "value" => "1"}]
          })

        assert Cohorts.to_sql(c) =~ field, "expected to_sql to include #{field}"
      end
    end
  end

  describe "Segment virtual fields" do
    alias Spectabas.Analytics.Segment

    test "returning expands to a visitor_id IN subquery scoped to site_id" do
      filters = [%{"field" => "returning", "op" => "is", "value" => "yes"}]
      sql = Segment.to_sql(filters, site_id: 42)

      assert sql =~ "visitor_id IN"
      assert sql =~ "countDistinct(toDate(timestamp)) > 1"
      assert sql =~ "site_id = "
    end

    test "returning drops when no site_id is provided" do
      filters = [%{"field" => "returning", "op" => "is", "value" => "yes"}]
      assert Segment.to_sql(filters) == ""
    end

    test "returning is_not flips the predicate" do
      filters = [%{"field" => "returning", "op" => "is_not", "value" => "yes"}]
      sql = Segment.to_sql(filters, site_id: 42)
      assert sql =~ "NOT ("
    end

    test "scraper_whitelisted and identified are flagged as pg_resolved" do
      assert Segment.pg_resolved?(%{
               "field" => "scraper_whitelisted",
               "op" => "is",
               "value" => "yes"
             })

      assert Segment.pg_resolved?(%{"field" => "identified", "op" => "is", "value" => "yes"})
      refute Segment.pg_resolved?(%{"field" => "returning", "op" => "is", "value" => "yes"})
      refute Segment.pg_resolved?(%{"field" => "ip_country", "op" => "is", "value" => "US"})
    end
  end
end
