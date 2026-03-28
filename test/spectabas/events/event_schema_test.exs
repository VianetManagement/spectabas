defmodule Spectabas.Events.EventSchemaTest do
  use ExUnit.Case, async: true

  alias Spectabas.Events.EventSchema

  describe "to_row/1" do
    test "converts event map to ClickHouse row" do
      event = %{
        event_id: "abc-123",
        site_id: 1,
        visitor_id: "visitor-1",
        session_id: "session-1",
        event_type: "pageview",
        event_name: "",
        timestamp: ~U[2026-03-27 12:00:00Z],
        url_path: "/hello",
        url_host: "example.com",
        referrer: "https://google.com",
        referrer_domain: "google.com",
        utm_source: "google",
        utm_medium: "cpc",
        utm_campaign: "spring",
        utm_term: "",
        utm_content: "",
        device_type: "desktop",
        browser: "Chrome",
        browser_version: "120.0",
        os: "macOS",
        os_version: "14.0",
        screen_width: 1920,
        screen_height: 1080,
        duration: 45,
        props: %{"page_type" => "blog"},
        ip_address: "1.2.3.4",
        ip_country: "US",
        ip_country_name: "United States",
        ip_continent: "NA",
        ip_continent_name: "North America",
        ip_region_code: "CA",
        ip_region_name: "California",
        ip_city: "San Francisco",
        ip_postal_code: "94102",
        ip_lat: 37.7749,
        ip_lon: -122.4194,
        ip_accuracy_radius: 20,
        ip_timezone: "America/Los_Angeles",
        ip_asn: 15169,
        ip_asn_org: "Google LLC",
        ip_org: "AS15169 Google LLC",
        ip_is_datacenter: 0,
        ip_is_vpn: 0,
        ip_is_tor: 0,
        ip_is_bot: 0,
        ip_gdpr_anonymized: 0
      }

      row = EventSchema.to_row(event)

      assert row["event_id"] == "abc-123"
      assert row["site_id"] == 1
      assert row["event_type"] == "pageview"
      assert row["url_path"] == "/hello"
      assert row["browser"] == "Chrome"
      assert row["ip_country"] == "US"
      assert row["ip_region_name"] == "California"
      assert row["duration_s"] == 45
      assert row["ip_is_bot"] == 0
      assert is_binary(row["properties"])
      assert Jason.decode!(row["properties"]) == %{"page_type" => "blog"}
    end

    test "handles nil values gracefully" do
      event = %{site_id: 1}
      row = EventSchema.to_row(event)

      assert row["site_id"] == 1
      assert row["visitor_id"] == ""
      assert row["ip_country"] == ""
      assert row["duration_s"] == 0
    end

    test "includes browser_fingerprint in output" do
      event = %{site_id: 1, browser_fingerprint: "fp_abc123def456"}
      row = EventSchema.to_row(event)

      assert row["browser_fingerprint"] == "fp_abc123def456"
    end

    test "browser_fingerprint defaults to empty string when absent" do
      event = %{site_id: 1}
      row = EventSchema.to_row(event)

      assert row["browser_fingerprint"] == ""
    end
  end
end
