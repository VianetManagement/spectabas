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

    test "datacenter with multiple pageviews is not bot" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 1,
        url_path: "/about",
        referrer_domain: "google.com",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event, %{pageview_count: 5}) != "bot"
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

    test "classifies buying intent from checkout page" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/checkout/step-1",
        referrer_domain: "",
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
      for site <- ["g2.com", "capterra.com", "trustradius.com", "producthunt.com"] do
        event = %{
          ip_is_bot: 0,
          ip_is_datacenter: 0,
          url_path: "/features",
          referrer_domain: site,
          utm_medium: "",
          utm_source: ""
        }

        assert IntentClassifier.classify(event) == "comparing",
               "Expected comparing for referrer #{site}"
      end
    end

    test "classifies support intent" do
      for path <- ["/help", "/contact", "/docs/api", "/faq", "/support/tickets"] do
        event = %{
          ip_is_bot: 0,
          ip_is_datacenter: 0,
          url_path: path,
          referrer_domain: "",
          utm_medium: "",
          utm_source: ""
        }

        assert IntentClassifier.classify(event) == "support",
               "Expected support for path #{path}"
      end
    end

    test "classifies returning visitor" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/blog/post-123",
        referrer_domain: "",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event, %{pageview_count: 1, is_returning: true}) ==
               "returning"
    end

    test "classifies returning visitor on engaging page as engaging" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/dashboard",
        referrer_domain: "",
        utm_medium: "",
        utm_source: ""
      }

      assert IntentClassifier.classify(event, %{pageview_count: 5, is_returning: true}) ==
               "engaging"
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

    test "classifies paid traffic as researching" do
      event = %{
        ip_is_bot: 0,
        ip_is_datacenter: 0,
        url_path: "/features",
        referrer_domain: "google.com",
        utm_medium: "cpc",
        utm_source: "google"
      }

      assert IntentClassifier.classify(event, %{pageview_count: 1}) == "researching"
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

    test "handles string map keys" do
      event = %{
        "ip_is_bot" => 0,
        "ip_is_datacenter" => 0,
        "url_path" => "/pricing",
        "referrer_domain" => "",
        "utm_medium" => "",
        "utm_source" => ""
      }

      assert IntentClassifier.classify(event) == "buying"
    end

    test "handles nil and missing values" do
      event = %{}
      assert IntentClassifier.classify(event) == "browsing"
    end
  end
end
