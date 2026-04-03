defmodule Spectabas.BraintreeIntegrationTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.{AdIntegration, Credentials}
  alias Spectabas.Sites.Site
  import Spectabas.AccountsFixtures

  setup do
    site =
      Repo.insert!(%Site{
        name: "Braintree Test Site",
        domain: "b.bt-test-#{System.unique_integer([:positive])}.com",
        public_key: Site.generate_public_key(),
        active: true,
        account_id: test_account().id
      })

    %{site: site}
  end

  describe "Braintree credentials" do
    test "save and retrieve credentials", %{site: site} do
      {:ok, site} =
        Credentials.save(site, "braintree", %{
          "merchant_id" => "test_merchant",
          "public_key" => "test_pub_key",
          "private_key" => "test_priv_key"
        })

      creds = Credentials.get_for_platform(site, "braintree")
      assert creds["merchant_id"] == "test_merchant"
      assert creds["public_key"] == "test_pub_key"
      assert creds["private_key"] == "test_priv_key"
    end

    test "configured? returns true when all three keys are set", %{site: site} do
      refute Credentials.configured?(site, "braintree")

      {:ok, site} =
        Credentials.save(site, "braintree", %{
          "merchant_id" => "m",
          "public_key" => "p",
          "private_key" => "k"
        })

      assert Credentials.configured?(site, "braintree")
    end

    test "configured? returns false when any key is empty", %{site: site} do
      {:ok, site} =
        Credentials.save(site, "braintree", %{
          "merchant_id" => "m",
          "public_key" => "",
          "private_key" => "k"
        })

      refute Credentials.configured?(site, "braintree")
    end
  end

  describe "Braintree integration record" do
    test "can create a Braintree integration", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "braintree", %{
          access_token: "test_merchant_id",
          refresh_token: "",
          account_id: "test_merchant_id",
          account_name: "Braintree"
        })

      assert integration.platform == "braintree"
      assert integration.status == "active"
    end

    test "can disconnect a Braintree integration", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "braintree", %{
          access_token: "test",
          refresh_token: "",
          account_id: "test",
          account_name: "Braintree"
        })

      {:ok, disconnected} = AdIntegrations.disconnect(integration)
      assert disconnected.status == "revoked"
    end
  end

  describe "sync frequency" do
    test "should_sync? returns true when never synced", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "braintree", %{
          access_token: "test",
          refresh_token: "",
          account_id: "test",
          account_name: "Braintree"
        })

      assert AdIntegrations.should_sync?(integration)
    end

    test "should_sync? respects frequency setting", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "braintree", %{
          access_token: "test",
          refresh_token: "",
          account_id: "test",
          account_name: "Braintree"
        })

      # Mark as just synced
      {:ok, synced} = AdIntegrations.mark_synced(integration)

      # Default frequency is 15 min for braintree — just synced, so should not sync again
      refute AdIntegrations.should_sync?(synced)
    end

    test "update_sync_frequency stores in extra map", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "braintree", %{
          access_token: "test",
          refresh_token: "",
          account_id: "test",
          account_name: "Braintree"
        })

      {:ok, updated} = AdIntegrations.update_sync_frequency(integration, 60)
      assert updated.extra["sync_frequency_minutes"] == 60
      assert AdIntegrations.sync_frequency(updated) == 60
    end

    test "sync_frequency returns default when not configured", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "braintree", %{
          access_token: "test",
          refresh_token: "",
          account_id: "test",
          account_name: "Braintree"
        })

      assert AdIntegrations.sync_frequency(integration) == 15
    end

    test "sync_frequency returns 360 for ad platforms", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "google_ads", %{
          access_token: "test",
          refresh_token: "test",
          account_id: "test",
          account_name: "Google"
        })

      assert AdIntegrations.sync_frequency(integration) == 360
    end
  end
end
