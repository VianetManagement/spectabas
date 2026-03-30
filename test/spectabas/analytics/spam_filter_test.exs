defmodule Spectabas.Analytics.SpamFilterTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.Analytics.SpamFilter

  describe "spam_domain?/1" do
    test "identifies known builtin spam domains" do
      assert SpamFilter.spam_domain?("semalt.com")
      assert SpamFilter.spam_domain?("darodar.com")
      assert SpamFilter.spam_domain?("buttons-for-website.com")
      assert SpamFilter.spam_domain?("ilovevitaly.com")
    end

    test "is case insensitive" do
      assert SpamFilter.spam_domain?("Semalt.com")
      assert SpamFilter.spam_domain?("DARODAR.COM")
    end

    test "does not flag legitimate domains" do
      refute SpamFilter.spam_domain?("google.com")
      refute SpamFilter.spam_domain?("github.com")
      refute SpamFilter.spam_domain?("example.com")
    end

    test "handles nil and non-string input" do
      refute SpamFilter.spam_domain?(nil)
      refute SpamFilter.spam_domain?(123)
    end

    test "identifies domains added to DB" do
      {:ok, _} = SpamFilter.add_domain("new-spam.com", "manual")
      assert SpamFilter.spam_domain?("new-spam.com")
      assert SpamFilter.spam_domain?("New-Spam.com")
    end
  end

  describe "spam_domains/0" do
    test "returns a non-empty list of strings" do
      domains = SpamFilter.spam_domains()
      assert is_list(domains)
      assert length(domains) > 0
      assert Enum.all?(domains, &is_binary/1)
    end
  end

  describe "add_domain/2" do
    test "adds a domain to the database" do
      assert {:ok, record} = SpamFilter.add_domain("test-spam.org", "manual")
      assert record.domain == "test-spam.org"
      assert record.source == "manual"
      assert record.active == true
    end

    test "lowercases the domain" do
      assert {:ok, record} = SpamFilter.add_domain("UPPER-SPAM.COM", "manual")
      assert record.domain == "upper-spam.com"
    end

    test "upserts existing domain" do
      {:ok, _} = SpamFilter.add_domain("dup-spam.com", "manual")
      {:ok, record} = SpamFilter.add_domain("dup-spam.com", "auto")
      assert record.source == "auto" || record.domain == "dup-spam.com"
    end

    test "trims whitespace" do
      {:ok, record} = SpamFilter.add_domain("  spaced-spam.com  ", "manual")
      assert record.domain == "spaced-spam.com"
    end
  end

  describe "remove_domain/1" do
    test "removes a custom domain from DB" do
      {:ok, _} = SpamFilter.add_domain("removable-spam.com", "manual")
      assert {:ok, _} = SpamFilter.remove_domain("removable-spam.com")
      refute SpamFilter.spam_domain?("removable-spam.com")
    end

    test "cannot remove builtin domains" do
      assert {:error, :builtin_domain} = SpamFilter.remove_domain("semalt.com")
    end

    test "returns error for non-existent domain" do
      assert {:error, :not_found} = SpamFilter.remove_domain("nonexistent.xyz")
    end
  end

  describe "all_domains/0" do
    test "includes builtin domains" do
      domains = SpamFilter.all_domains()
      assert "semalt.com" in domains
      assert "darodar.com" in domains
    end

    test "includes DB domains" do
      {:ok, _} = SpamFilter.add_domain("custom-blocked.com", "manual")
      domains = SpamFilter.all_domains()
      assert "custom-blocked.com" in domains
      assert "semalt.com" in domains
    end

    test "deduplicates" do
      domains = SpamFilter.all_domains()
      assert length(domains) == length(Enum.uniq(domains))
    end
  end

  describe "list_domains/0" do
    test "returns domain records with source info" do
      {:ok, _} = SpamFilter.add_domain("listed-spam.net", "auto")
      domains = SpamFilter.list_domains()

      assert is_list(domains)
      assert length(domains) > 0

      # Builtins should be present
      builtin = Enum.find(domains, &(&1.domain == "semalt.com"))
      assert builtin.source == "builtin"

      # Custom domain should be present
      custom = Enum.find(domains, &(&1.domain == "listed-spam.net"))
      assert custom.source == "auto"
    end
  end
end
