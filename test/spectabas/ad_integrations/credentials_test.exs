defmodule Spectabas.AdIntegrations.CredentialsTest do
  use SpectabasWeb.ConnCase

  alias Spectabas.AdIntegrations.Credentials

  setup do
    site =
      Spectabas.Repo.insert!(%Spectabas.Sites.Site{
        name: "Creds Test",
        domain: "b.credstest.com",
        public_key: "creds_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off"
      })

    %{site: site}
  end

  describe "get_for_platform/2" do
    test "returns empty map when no credentials stored", %{site: site} do
      assert Credentials.get_for_platform(site, "google_ads") == %{}
    end

    test "returns credentials after saving", %{site: site} do
      creds = %{"client_id" => "test_id", "client_secret" => "test_secret"}
      {:ok, updated} = Credentials.save(site, "google_ads", creds)
      assert Credentials.get_for_platform(updated, "google_ads") == creds
    end

    test "returns empty map for unconfigured platform when other platform is configured", %{
      site: site
    } do
      {:ok, updated} =
        Credentials.save(site, "google_ads", %{"client_id" => "id", "client_secret" => "sec"})

      assert Credentials.get_for_platform(updated, "bing_ads") == %{}
    end
  end

  describe "save/3" do
    test "stores credentials encrypted", %{site: site} do
      creds = %{"client_id" => "my_id", "client_secret" => "my_secret"}
      {:ok, updated} = Credentials.save(site, "google_ads", creds)

      # The raw encrypted field should not contain plaintext
      assert is_binary(updated.ad_credentials_encrypted)
      refute String.contains?(updated.ad_credentials_encrypted || "", "my_secret")
    end

    test "preserves credentials for other platforms", %{site: site} do
      {:ok, s1} =
        Credentials.save(site, "google_ads", %{
          "client_id" => "g_id",
          "client_secret" => "g_sec"
        })

      {:ok, s2} =
        Credentials.save(s1, "meta_ads", %{"app_id" => "m_id", "app_secret" => "m_sec"})

      assert Credentials.get_for_platform(s2, "google_ads") == %{
               "client_id" => "g_id",
               "client_secret" => "g_sec"
             }

      assert Credentials.get_for_platform(s2, "meta_ads") == %{
               "app_id" => "m_id",
               "app_secret" => "m_sec"
             }
    end

    test "overwrites credentials for same platform", %{site: site} do
      {:ok, s1} =
        Credentials.save(site, "google_ads", %{
          "client_id" => "old_id",
          "client_secret" => "old"
        })

      {:ok, s2} =
        Credentials.save(s1, "google_ads", %{
          "client_id" => "new_id",
          "client_secret" => "new"
        })

      assert Credentials.get_for_platform(s2, "google_ads")["client_id"] == "new_id"
    end
  end

  describe "delete/2" do
    test "removes credentials for a platform", %{site: site} do
      {:ok, s1} =
        Credentials.save(site, "google_ads", %{"client_id" => "id", "client_secret" => "sec"})

      {:ok, s2} = Credentials.delete(s1, "google_ads")
      assert Credentials.get_for_platform(s2, "google_ads") == %{}
    end

    test "preserves other platform credentials when deleting one", %{site: site} do
      {:ok, s1} =
        Credentials.save(site, "google_ads", %{
          "client_id" => "g_id",
          "client_secret" => "g_sec"
        })

      {:ok, s2} =
        Credentials.save(s1, "bing_ads", %{"client_id" => "b_id", "client_secret" => "b_sec"})

      {:ok, s3} = Credentials.delete(s2, "google_ads")

      assert Credentials.get_for_platform(s3, "google_ads") == %{}

      assert Credentials.get_for_platform(s3, "bing_ads") == %{
               "client_id" => "b_id",
               "client_secret" => "b_sec"
             }
    end
  end

  describe "configured?/2" do
    test "returns false when no credentials", %{site: site} do
      refute Credentials.configured?(site, "google_ads")
      refute Credentials.configured?(site, "bing_ads")
      refute Credentials.configured?(site, "meta_ads")
    end

    test "returns true for google_ads with client_id and client_secret", %{site: site} do
      {:ok, updated} =
        Credentials.save(site, "google_ads", %{
          "client_id" => "id",
          "client_secret" => "sec"
        })

      assert Credentials.configured?(updated, "google_ads")
    end

    test "returns true for meta_ads with app_id and app_secret", %{site: site} do
      {:ok, updated} =
        Credentials.save(site, "meta_ads", %{"app_id" => "id", "app_secret" => "sec"})

      assert Credentials.configured?(updated, "meta_ads")
    end

    test "returns false with empty client_id", %{site: site} do
      {:ok, updated} =
        Credentials.save(site, "google_ads", %{"client_id" => "", "client_secret" => "sec"})

      refute Credentials.configured?(updated, "google_ads")
    end
  end

  describe "get_all/1" do
    test "returns all platform credentials", %{site: site} do
      {:ok, s1} =
        Credentials.save(site, "google_ads", %{"client_id" => "g"})

      {:ok, s2} = Credentials.save(s1, "meta_ads", %{"app_id" => "m"})

      all = Credentials.get_all(s2)
      assert all["google_ads"]["client_id"] == "g"
      assert all["meta_ads"]["app_id"] == "m"
    end
  end
end
