defmodule Spectabas.Analytics.ChannelClassifierTest do
  use ExUnit.Case, async: true

  alias Spectabas.Analytics.ChannelClassifier

  describe "classify/3" do
    test "Google is Search Engines" do
      assert ChannelClassifier.classify("google.com") == "Search Engines"
    end

    test "Bing is Search Engines" do
      assert ChannelClassifier.classify("bing.com") == "Search Engines"
    end

    test "facebook.com is Social Networks" do
      assert ChannelClassifier.classify("facebook.com") == "Social Networks"
    end

    test "twitter.com is Social Networks" do
      assert ChannelClassifier.classify("twitter.com") == "Social Networks"
    end

    test "chatgpt.com is AI Assistants" do
      assert ChannelClassifier.classify("chatgpt.com") == "AI Assistants"
    end

    test "claude.ai is AI Assistants" do
      assert ChannelClassifier.classify("claude.ai") == "AI Assistants"
    end

    test "perplexity.ai is AI Assistants" do
      assert ChannelClassifier.classify("perplexity.ai") == "AI Assistants"
    end

    test "mail.google.com is Email" do
      assert ChannelClassifier.classify("mail.google.com") == "Email"
    end

    test "utm_medium=cpc is Paid Search" do
      assert ChannelClassifier.classify("", "", "cpc") == "Paid Search"
    end

    test "utm_medium=ppc is Paid Search" do
      assert ChannelClassifier.classify("", "", "ppc") == "Paid Search"
    end

    test "utm_medium=email is Email" do
      assert ChannelClassifier.classify("", "", "email") == "Email"
    end

    test "utm_medium=social is Social Networks" do
      assert ChannelClassifier.classify("", "", "social") == "Social Networks"
    end

    test "utm_medium=paid_social is Paid Social" do
      assert ChannelClassifier.classify("", "", "paid_social") == "Paid Social"
    end

    test "empty referrer and empty UTM is Direct" do
      assert ChannelClassifier.classify("", "", "") == "Direct"
    end

    test "unknown domain is Websites" do
      assert ChannelClassifier.classify("someblog.org") == "Websites"
    end

    test "utm_source only with no referrer is Other Campaigns" do
      assert ChannelClassifier.classify("", "newsletter") == "Other Campaigns"
    end

    test "UTM medium takes priority over referrer domain" do
      assert ChannelClassifier.classify("google.com", "", "cpc") == "Paid Search"
    end
  end

  describe "channel_color/1" do
    test "each channel returns a non-empty string" do
      channels = [
        "Search Engines",
        "Social Networks",
        "AI Assistants",
        "Direct",
        "Email",
        "Paid Search",
        "Paid Social",
        "Websites",
        "Other Campaigns",
        "Unknown"
      ]

      for channel <- channels do
        color = ChannelClassifier.channel_color(channel)
        assert is_binary(color) and color != "", "Expected non-empty color for #{channel}"
      end
    end
  end
end
