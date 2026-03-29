defmodule Spectabas.Events.RumPayloadTest do
  use ExUnit.Case, async: true

  alias Spectabas.Events.{CollectPayload, EventSchema}

  describe "RUM event payload validation" do
    test "accepts _rum custom event with navigation timing props" do
      params = %{
        "t" => "custom",
        "n" => "_rum",
        "u" => "https://example.com/page",
        "r" => "",
        "vid" => "fp_abc123",
        "sw" => 1920,
        "sh" => 1080,
        "d" => 0,
        "p" => %{
          "dns" => "5",
          "tcp" => "10",
          "tls" => "8",
          "ttfb" => "45",
          "download" => "120",
          "dom_interactive" => "350",
          "dom_complete" => "500",
          "page_load" => "1234",
          "transfer_size" => "54321",
          "dom_size" => "248",
          "fcp" => "280"
        },
        "_bot" => 0,
        "_hi" => 1,
        "_fp" => "fp_abc123"
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload.t == "custom"
      assert payload.n == "_rum"
      assert payload.p["page_load"] == "1234"
      assert payload.p["ttfb"] == "45"
      assert payload.p["fcp"] == "280"
      assert payload.p["dom_complete"] == "500"
      assert payload.p["transfer_size"] == "54321"
    end

    test "accepts _cwv custom event with Core Web Vitals props" do
      params = %{
        "t" => "custom",
        "n" => "_cwv",
        "u" => "https://example.com/",
        "r" => "",
        "vid" => "fp_xyz789",
        "sw" => 1440,
        "sh" => 900,
        "d" => 0,
        "p" => %{
          "lcp" => "2100",
          "cls" => "0.05",
          "fid" => "12"
        },
        "_bot" => 0,
        "_hi" => 1,
        "_fp" => "fp_xyz789"
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload.t == "custom"
      assert payload.n == "_cwv"
      assert payload.p["lcp"] == "2100"
      assert payload.p["cls"] == "0.05"
      assert payload.p["fid"] == "12"
    end

    test "accepts _cwv event without FID (no user interaction)" do
      params = %{
        "t" => "custom",
        "n" => "_cwv",
        "u" => "https://example.com/",
        "r" => "",
        "vid" => "fp_abc",
        "d" => 0,
        "p" => %{
          "lcp" => "1800",
          "cls" => "0"
        }
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload.p["lcp"] == "1800"
      assert payload.p["cls"] == "0"
      refute Map.has_key?(payload.p, "fid")
    end

    test "accepts _cwv event with CLS of 0 (perfect stability)" do
      params = %{
        "t" => "custom",
        "n" => "_cwv",
        "u" => "https://example.com/",
        "d" => 0,
        "p" => %{"lcp" => "1500", "cls" => "0"}
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload.p["cls"] == "0"
    end

    test "accepts _rum event with minimal props (only page_load)" do
      params = %{
        "t" => "custom",
        "n" => "_rum",
        "u" => "https://example.com/",
        "d" => 0,
        "p" => %{"page_load" => "800"}
      }

      assert {:ok, %CollectPayload{}} = CollectPayload.validate(params)
    end

    test "all RUM property values must be strings" do
      params = %{
        "t" => "custom",
        "n" => "_rum",
        "u" => "https://example.com/",
        "d" => 0,
        "p" => %{"page_load" => 1234}
      }

      # Integer values in props should fail validation (all values must be strings)
      assert {:error, _} = CollectPayload.validate(params)
    end

    test "rejects _rum event with too many properties" do
      props = for i <- 1..21, into: %{}, do: {"metric_#{i}", "#{i}"}

      params = %{
        "t" => "custom",
        "n" => "_rum",
        "u" => "https://example.com/",
        "d" => 0,
        "p" => props
      }

      assert {:error, _} = CollectPayload.validate(params)
    end
  end

  describe "RUM event schema conversion" do
    test "converts _rum event to ClickHouse row with properties JSON" do
      event = %{
        event_id: "rum-001",
        site_id: 1,
        visitor_id: "fp_abc123",
        session_id: "sess-1",
        event_type: "custom",
        event_name: "_rum",
        timestamp: ~U[2026-03-28 12:00:00Z],
        url_path: "/pricing",
        url_host: "example.com",
        referrer: "",
        referrer_domain: "",
        device_type: "desktop",
        browser: "Chrome",
        browser_version: "120.0",
        os: "macOS",
        os_version: "14.0",
        screen_width: 1920,
        screen_height: 1080,
        duration: 0,
        props: %{
          "page_load" => "1234",
          "ttfb" => "45",
          "fcp" => "280",
          "dom_complete" => "500",
          "transfer_size" => "54321"
        },
        ip_address: "1.2.3.4",
        browser_fingerprint: "fp_abc123"
      }

      row = EventSchema.to_row(event)

      assert row["event_type"] == "custom"
      assert row["event_name"] == "_rum"
      assert row["url_path"] == "/pricing"

      props = Jason.decode!(row["properties"])
      assert props["page_load"] == "1234"
      assert props["ttfb"] == "45"
      assert props["fcp"] == "280"
      assert props["dom_complete"] == "500"
      assert props["transfer_size"] == "54321"
    end

    test "converts _cwv event to ClickHouse row" do
      event = %{
        event_id: "cwv-001",
        site_id: 1,
        visitor_id: "fp_xyz789",
        session_id: "sess-2",
        event_type: "custom",
        event_name: "_cwv",
        timestamp: ~U[2026-03-28 12:00:00Z],
        url_path: "/",
        url_host: "example.com",
        referrer: "",
        referrer_domain: "",
        device_type: "smartphone",
        browser: "Safari",
        browser_version: "17.0",
        os: "iOS",
        os_version: "17.0",
        screen_width: 390,
        screen_height: 844,
        duration: 0,
        props: %{
          "lcp" => "2100",
          "cls" => "0.05",
          "fid" => "12"
        },
        ip_address: "5.6.7.8",
        browser_fingerprint: "fp_xyz789"
      }

      row = EventSchema.to_row(event)

      assert row["event_type"] == "custom"
      assert row["event_name"] == "_cwv"
      assert row["device_type"] == "smartphone"

      props = Jason.decode!(row["properties"])
      assert props["lcp"] == "2100"
      assert props["cls"] == "0.05"
      assert props["fid"] == "12"
    end

    test "converts _cwv event without FID" do
      event = %{
        site_id: 1,
        event_type: "custom",
        event_name: "_cwv",
        props: %{"lcp" => "1800", "cls" => "0"}
      }

      row = EventSchema.to_row(event)
      props = Jason.decode!(row["properties"])
      assert props["lcp"] == "1800"
      assert props["cls"] == "0"
      refute Map.has_key?(props, "fid")
    end

    test "_rum properties are preserved through JSON encoding" do
      all_rum_props = %{
        "dns" => "5",
        "tcp" => "10",
        "tls" => "8",
        "ttfb" => "45",
        "download" => "120",
        "dom_interactive" => "350",
        "dom_complete" => "500",
        "page_load" => "1234",
        "transfer_size" => "54321",
        "dom_size" => "248",
        "fcp" => "280"
      }

      event = %{site_id: 1, event_type: "custom", event_name: "_rum", props: all_rum_props}
      row = EventSchema.to_row(event)
      decoded = Jason.decode!(row["properties"])

      for {key, value} <- all_rum_props do
        assert decoded[key] == value,
               "Property #{key} expected #{value}, got #{inspect(decoded[key])}"
      end
    end
  end
end
