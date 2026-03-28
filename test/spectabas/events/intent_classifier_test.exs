defmodule Spectabas.Events.IntentClassifierTest do
  use ExUnit.Case, async: true

  alias Spectabas.Events.IntentClassifier

  describe "classify/2" do
    test "classifies bot traffic" do
      event = %{ip_is_bot: 1, url_path: "/", referrer_domain: "", utm_medium: "", utm_source: ""}
      assert IntentClassifier.classify(event) == "bot"
    end

    test "classifies datacenter with single pageview as bot" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 1,
        url_path: "/",
        referrer_domain: "",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event, %{pageview_count: 0}) == "bot"
    end

    test "classifies buying intent from pricing page" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/pricing",
        referrer_domain: "google.com",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event) == "buying"
    end

    test "classifies buying intent from paid ad on pricing" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/pricing",
        referrer_domain: "google.com",
        utm_medium: "cpc",
        utm_source: "google"
      }

      assert IntentClassifier.classify(event) == "buying"
    end

    test "classifies comparison referrer" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/features",
        referrer_domain: "g2.com",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event) == "comparing"
    end

    test "classifies support intent" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/help/getting-started",
        referrer_domain: "",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event) == "support"
    end

    test "classifies returning visitor" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/dashboard",
        referrer_domain: "",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event, %{pageview_count: 5, is_returning: true}) ==
               "returning"
    end

    test "classifies researching from high pageviews" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/blog/article",
        referrer_domain: "google.com",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event, %{pageview_count: 5}) == "researching"
    end

    test "classifies browsing as default" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/blog/article",
        referrer_domain: "google.com",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event, %{pageview_count: 1}) == "browsing"
    end
  end
end
