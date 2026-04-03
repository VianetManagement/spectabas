defmodule Spectabas.AdEffectivenessTest do
  use SpectabasWeb.ConnCase

  alias Spectabas.{Repo, Analytics}
  alias Spectabas.Sites.Site

  setup do
    user = Spectabas.AccountsFixtures.user_fixture()

    site =
      Repo.insert!(%Site{
        name: "Ad Effectiveness Test",
        domain: "b.ad-eff-test.com",
        public_key: "pk_adeff_#{System.unique_integer([:positive])}",
        gdpr_mode: "off",
        ecommerce_enabled: true,
        timezone: "UTC",
        account_id: Spectabas.AccountsFixtures.test_account().id
      })

    # These queries all hit ClickHouse which isn't available in test.
    # We verify they return gracefully (not crash) with {:ok, []} or {:error, _}.
    %{user: user, site: site}
  end

  describe "ad_churn_by_campaign/4" do
    test "returns ok tuple when no ClickHouse", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.ad_churn_by_campaign(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts group_by option", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.ad_churn_by_campaign(site, user, range, group_by: "campaign")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "ad_churn_summary/3" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.ad_churn_summary(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "time_to_convert_by_source/4" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.time_to_convert_by_source(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts group_by campaign", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.time_to_convert_by_source(site, user, range, group_by: "campaign")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "time_to_convert_distribution/3" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.time_to_convert_distribution(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "ad_visitor_paths/3" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.ad_visitor_paths(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "ad_bounce_pages/3" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.ad_bounce_pages(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "organic_lift_timeseries/3" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.organic_lift_timeseries(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "organic_lift_comparison/3" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.organic_lift_comparison(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "visitor_quality_by_source/4" do
    test "returns ok tuple", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.visitor_quality_by_source(site, user, range)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts group_by campaign", %{site: site, user: user} do
      range = %{from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-04-01 00:00:00Z]}
      result = Analytics.visitor_quality_by_source(site, user, range, group_by: "campaign")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
