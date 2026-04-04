defmodule Spectabas.StripeIntegrationTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.AdIntegrations
  alias Spectabas.AdIntegrations.{AdIntegration, Credentials, Vault}
  alias Spectabas.Sites.Site
  import Spectabas.AccountsFixtures

  setup do
    site =
      Repo.insert!(%Site{
        name: "Stripe Test Site",
        domain: "b.stripe-test-#{System.unique_integer([:positive])}.com",
        public_key: Site.generate_public_key(),
        active: true,
        account_id: test_account().id
      })

    %{site: site}
  end

  describe "Stripe credentials" do
    test "save and retrieve Stripe API key", %{site: site} do
      {:ok, site} = Credentials.save(site, "stripe", %{"api_key" => "sk_live_test123"})

      creds = Credentials.get_for_platform(site, "stripe")
      assert creds["api_key"] == "sk_live_test123"
    end

    test "configured? returns true when API key is set", %{site: site} do
      refute Credentials.configured?(site, "stripe")

      {:ok, site} = Credentials.save(site, "stripe", %{"api_key" => "sk_live_test123"})
      assert Credentials.configured?(site, "stripe")
    end

    test "configured? returns false when API key is empty", %{site: site} do
      {:ok, site} = Credentials.save(site, "stripe", %{"api_key" => ""})
      refute Credentials.configured?(site, "stripe")
    end
  end

  describe "Stripe integration record" do
    test "can create a Stripe integration", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "stripe", %{
          access_token: "sk_live_test123",
          refresh_token: "",
          account_id: "",
          account_name: "Stripe"
        })

      assert integration.platform == "stripe"
      assert integration.status == "active"
      assert AdIntegrations.decrypt_access_token(integration) == "sk_live_test123"
    end

    test "can disconnect a Stripe integration", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "stripe", %{
          access_token: "sk_live_test123",
          refresh_token: "",
          account_id: "",
          account_name: "Stripe"
        })

      {:ok, disconnected} = AdIntegrations.disconnect(integration)
      assert disconnected.status == "revoked"
    end

    test "Stripe token never expires", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "stripe", %{
          access_token: "sk_live_test123",
          refresh_token: "",
          account_id: "",
          account_name: "Stripe"
        })

      refute AdIntegrations.token_expired?(integration)
    end

    test "mark_synced and mark_error work for Stripe", %{site: site} do
      {:ok, integration} =
        AdIntegrations.connect(site.id, "stripe", %{
          access_token: "sk_live_test123",
          refresh_token: "",
          account_id: "",
          account_name: "Stripe"
        })

      {:ok, synced} = AdIntegrations.mark_synced(integration)
      assert synced.last_synced_at != nil
      assert synced.last_error == nil

      {:ok, errored} = AdIntegrations.mark_error(synced, "test error")
      assert errored.status == "active"
      assert errored.last_error == "test error"
    end
  end
end
