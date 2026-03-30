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

    test "force-sent _rum event without page_load preserves partial metrics" do
      # When visibilitychange fires before load event, page_load is absent
      # but ttfb, fcp, dom_interactive should still be present
      partial_props = %{
        "dns" => "5",
        "tcp" => "10",
        "ttfb" => "45",
        "fcp" => "280",
        "dom_interactive" => "350",
        "dom_size" => "248"
      }

      event = %{site_id: 1, event_type: "custom", event_name: "_rum", props: partial_props}
      row = EventSchema.to_row(event)
      decoded = Jason.decode!(row["properties"])

      assert decoded["ttfb"] == "45"
      assert decoded["fcp"] == "280"
      refute Map.has_key?(decoded, "page_load")
      refute Map.has_key?(decoded, "dom_complete")
    end
  end

  describe "RUM analytics query key alignment" do
    # These tests verify that the property key names used in ClickHouse queries
    # exactly match the key names sent by the tracker's collectRUM function.
    # A mismatch here causes metrics to show as 0 on the dashboard.

    @tracker_rum_keys ~w(dns tcp tls ttfb download dom_interactive dom_complete
                         page_load transfer_size dom_size fcp)
    @tracker_cwv_keys ~w(lcp cls fid)

    @queried_rum_keys ~w(page_load ttfb fcp dom_complete transfer_size)
    @queried_cwv_keys ~w(lcp cls fid)

    test "all queried RUM keys exist in tracker's output keys" do
      for key <- @queried_rum_keys do
        assert key in @tracker_rum_keys,
               "Analytics queries extract '#{key}' but tracker does not send it"
      end
    end

    test "all queried CWV keys exist in tracker's output keys" do
      for key <- @queried_cwv_keys do
        assert key in @tracker_cwv_keys,
               "Analytics queries extract '#{key}' but tracker does not send it"
      end
    end

    test "JSONExtractString key names in RUM queries match tracker property names" do
      # Read the analytics module source to verify key name alignment
      source_path = Path.join([__DIR__, "..", "..", "..", "lib", "spectabas", "analytics.ex"])

      if File.exists?(source_path) do
        content = File.read!(source_path)

        # Extract only the rum_ function bodies (between def rum_ and the next def or end)
        rum_sections =
          Regex.scan(~r/def rum_\w+.*?(?=\n  def |\n  defp |\nend)/s, content)
          |> Enum.map(fn [match] -> match end)
          |> Enum.join("\n")

        # Every JSONExtractString key used in rum_ functions should be a valid tracker key
        all_valid_keys = @tracker_rum_keys ++ @tracker_cwv_keys

        Regex.scan(~r/JSONExtractString\((?:r\.)?properties,\s*'(\w+)'\)/, rum_sections)
        |> Enum.map(fn [_, key] -> key end)
        |> Enum.uniq()
        |> Enum.each(fn key ->
          assert key in all_valid_keys,
                 "RUM query extracts '#{key}' which is not in the tracker's output keys: #{inspect(all_valid_keys)}"
        end)
      end
    end
  end

  describe "tracker script RUM scheduling" do
    # Verify the tracker uses event-driven RUM collection (not polling)
    # to prevent the race condition where early force-sends block complete data

    setup do
      script_path = Path.join([__DIR__, "..", "..", "..", "priv", "static", "s.js"])
      %{script: File.read!(script_path)}
    end

    test "does not use polling-based RUM delays", %{script: script} do
      # The old approach had rumDelays = [500, 1500, 3000, 5000, 8000]
      # which caused race conditions on heavy pages
      refute script =~ "rumDelays",
             "Tracker should not use polling-based rumDelays array"
    end

    test "does not force-send at 10s timeout", %{script: script} do
      # The old 10s force-send was too aggressive for heavy WordPress pages
      # where load event fires at 12-20s
      refute script =~ "setTimeout(function () { collectRUM(true); }, 10000)",
             "Tracker should not force-send RUM at 10s (too aggressive for heavy pages)"
    end

    test "uses load event as primary RUM trigger", %{script: script} do
      assert script =~ ~r/window\.addEventListener\("load"/,
             "Tracker should wait for load event as primary RUM trigger"
    end

    test "uses visibilitychange as safety net", %{script: script} do
      assert script =~ ~r/visibilitychange.*collectRUM\(true\)/s,
             "Tracker should force-send RUM on visibilitychange (safety net)"
    end

    test "has a generous final timeout (30s)", %{script: script} do
      assert script =~ "30000",
             "Tracker should have a 30s final fallback timeout"
    end

    test "pageview rate limiting via sessionStorage", %{script: script} do
      assert script =~ "pvMinInterval",
             "Tracker should have a minimum interval between pageviews"

      assert script =~ "sessionStorage",
             "Tracker should use sessionStorage for pageview rate limiting"

      assert script =~ "sendPageview",
             "Tracker should use sendPageview wrapper (not raw sendEvent for pageviews)"
    end

    test "collectRUM function checks rumSent flag", %{script: script} do
      assert script =~ "if (rumSent) return",
             "collectRUM must check rumSent flag to prevent duplicate sends"
    end

    test "collectRUM sends page_load when loadEventEnd > 0", %{script: script} do
      assert script =~ ~r/loadEventEnd > 0.*page_load/s,
             "collectRUM must include page_load when loadEventEnd is available"
    end

    test "mapToStrings converts values to strings and filters NaN", %{script: script} do
      assert script =~ "result[k] = String(v)",
             "mapToStrings must convert property values to strings"

      assert script =~ "v === v",
             "mapToStrings must filter NaN values (v === v is false for NaN)"
    end

    test "uses nav.startTime NOT nav.navigationStart for PerformanceNavigationTiming", %{
      script: script
    } do
      # PerformanceNavigationTiming has startTime (always 0), NOT navigationStart.
      # navigationStart only exists on the deprecated performance.timing object.
      # Using nav.navigationStart produces undefined, and number - undefined = NaN.
      assert script =~ "nav.startTime",
             "Must use nav.startTime for PerformanceNavigationTiming baseline"

      # Verify we use navStart variable (derived from nav.startTime) for the calculations
      assert script =~ ~r/nav\.domInteractive - navStart/,
             "dom_interactive must subtract navStart (from nav.startTime), not nav.navigationStart"

      assert script =~ ~r/nav\.loadEventEnd - navStart/,
             "page_load must subtract navStart (from nav.startTime), not nav.navigationStart"

      assert script =~ ~r/nav\.domContentLoadedEventEnd - navStart/,
             "dom_complete must subtract navStart (from nav.startTime), not nav.navigationStart"

      # Ensure the deprecated property name is NOT used on the modern API path
      refute script =~ ~r/nav\.navigationStart/,
             "Must NOT use nav.navigationStart — it doesn't exist on PerformanceNavigationTiming"
    end
  end
end
