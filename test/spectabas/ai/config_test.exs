defmodule Spectabas.AI.ConfigTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.AI.Config

  import Spectabas.AccountsFixtures

  setup do
    account = test_account()

    site =
      Repo.insert!(%Spectabas.Sites.Site{
        name: "AI Config Test Site",
        domain: "b.aiconfig-test.com",
        public_key: "aiconfig_#{System.unique_integer([:positive])}",
        active: true,
        account_id: account.id
      })

    %{site: site}
  end

  describe "get/1" do
    test "returns empty map when ai_config_encrypted is nil", %{site: site} do
      assert site.ai_config_encrypted == nil
      assert Config.get(site) == %{}
    end

    test "returns empty map when ai_config_encrypted is empty binary", %{site: site} do
      site = %{site | ai_config_encrypted: <<>>}
      assert Config.get(site) == %{}
    end

    test "returns decrypted config after save", %{site: site} do
      config = %{"provider" => "anthropic", "api_key" => "sk-test-123", "model" => "claude-haiku-4-5-20251001"}
      {:ok, updated_site} = Config.save(site, config)

      assert Config.get(updated_site) == config
    end
  end

  describe "save/2" do
    test "encrypts and stores config on the site", %{site: site} do
      config = %{"provider" => "openai", "api_key" => "sk-openai-xyz", "model" => "gpt-4o-mini"}
      assert {:ok, updated_site} = Config.save(site, config)

      # The encrypted field should be set and not be the raw JSON
      assert updated_site.ai_config_encrypted != nil
      refute updated_site.ai_config_encrypted == Jason.encode!(config)

      # Reading back should return the original config
      assert Config.get(updated_site) == config
    end

    test "can be read back after reloading from DB", %{site: site} do
      config = %{"provider" => "google", "api_key" => "AIza-test", "model" => "gemini-2.0-flash"}
      {:ok, _updated_site} = Config.save(site, config)

      reloaded_site = Repo.get!(Spectabas.Sites.Site, site.id)
      assert Config.get(reloaded_site) == config
    end

    test "overwrites previous config", %{site: site} do
      config1 = %{"provider" => "anthropic", "api_key" => "sk-old"}
      {:ok, site} = Config.save(site, config1)
      assert Config.get(site)["api_key"] == "sk-old"

      config2 = %{"provider" => "openai", "api_key" => "sk-new"}
      {:ok, site} = Config.save(site, config2)
      assert Config.get(site) == config2
    end
  end

  describe "configured?/1" do
    test "returns false when ai_config_encrypted is nil", %{site: site} do
      refute Config.configured?(site)
    end

    test "returns false when provider is nil", %{site: site} do
      {:ok, site} = Config.save(site, %{"api_key" => "sk-test"})
      refute Config.configured?(site)
    end

    test "returns false when provider is empty string", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "", "api_key" => "sk-test"})
      refute Config.configured?(site)
    end

    test "returns false when provider is 'none'", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "none", "api_key" => "sk-test"})
      refute Config.configured?(site)
    end

    test "returns false when api_key is nil", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "anthropic"})
      refute Config.configured?(site)
    end

    test "returns false when api_key is empty string", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "anthropic", "api_key" => ""})
      refute Config.configured?(site)
    end

    test "returns true when provider and api_key are present", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "anthropic", "api_key" => "sk-test-123"})
      assert Config.configured?(site)
    end

    test "returns true for all valid providers", %{site: site} do
      for provider <- ["anthropic", "openai", "google"] do
        {:ok, site} = Config.save(site, %{"provider" => provider, "api_key" => "key-#{provider}"})
        assert Config.configured?(site), "Expected configured? to be true for provider: #{provider}"
      end
    end
  end

  describe "credentials/1" do
    test "returns provider, api_key, and model from config", %{site: site} do
      config = %{"provider" => "anthropic", "api_key" => "sk-abc", "model" => "claude-sonnet-4-6"}
      {:ok, site} = Config.save(site, config)

      assert {"anthropic", "sk-abc", "claude-sonnet-4-6"} = Config.credentials(site)
    end

    test "uses default model when model is not specified for anthropic", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "anthropic", "api_key" => "sk-abc"})
      {_provider, _key, model} = Config.credentials(site)
      assert model == "claude-haiku-4-5-20251001"
    end

    test "uses default model when model is not specified for openai", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "openai", "api_key" => "sk-abc"})
      {_provider, _key, model} = Config.credentials(site)
      assert model == "gpt-4o-mini"
    end

    test "uses default model when model is not specified for google", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "google", "api_key" => "AIza-test"})
      {_provider, _key, model} = Config.credentials(site)
      assert model == "gemini-2.0-flash"
    end

    test "returns nil model for unknown provider", %{site: site} do
      {:ok, site} = Config.save(site, %{"provider" => "unknown", "api_key" => "key"})
      {"unknown", "key", nil} = Config.credentials(site)
    end

    test "returns nils when no config is set", %{site: site} do
      {nil, nil, nil} = Config.credentials(site)
    end
  end

  describe "providers/0" do
    test "returns all supported providers" do
      providers = Config.providers()
      assert Map.has_key?(providers, "anthropic")
      assert Map.has_key?(providers, "openai")
      assert Map.has_key?(providers, "google")
    end

    test "each provider has label, models, and default_model" do
      for {_key, info} <- Config.providers() do
        assert is_binary(info.label)
        assert is_list(info.models)
        assert length(info.models) > 0
        assert is_binary(info.default_model)
      end
    end
  end
end
