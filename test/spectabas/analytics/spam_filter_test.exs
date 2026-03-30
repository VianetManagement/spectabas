defmodule Spectabas.Analytics.SpamFilterTest do
  use ExUnit.Case, async: true

  alias Spectabas.Analytics.SpamFilter

  describe "spam_domain?/1" do
    test "identifies known spam domains" do
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
  end

  describe "spam_domains/0" do
    test "returns a non-empty list of strings" do
      domains = SpamFilter.spam_domains()
      assert is_list(domains)
      assert length(domains) > 0
      assert Enum.all?(domains, &is_binary/1)
    end
  end
end
