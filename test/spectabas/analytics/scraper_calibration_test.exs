defmodule Spectabas.Analytics.ScraperCalibrationTest do
  use ExUnit.Case, async: true

  alias Spectabas.Analytics.ScraperCalibration

  @sample_baseline %{
    total_visitors: 12500,
    pageview_distribution: %{
      p50: 2,
      p75: 5,
      p90: 12,
      p95: 28,
      p99: 85,
      avg: 4.7
    },
    network: %{
      datacenter: 340,
      vpn: 820,
      residential: 11340
    },
    referrer: %{
      direct: 4200,
      referred: 8300
    },
    devices: [
      %{type: "Desktop", visitors: 7200},
      %{type: "Mobile", visitors: 4800},
      %{type: "Tablet", visitors: 500}
    ],
    top_asns: [
      %{
        asn: "AS7922",
        org: "Comcast Cable",
        datacenter: false,
        vpn: false,
        visitors: 1200,
        total_pages: 3400
      },
      %{
        asn: "AS14618",
        org: "Amazon.com Inc.",
        datacenter: true,
        vpn: false,
        visitors: 180,
        total_pages: 14200
      },
      %{
        asn: "AS9009",
        org: "M247 Ltd",
        datacenter: true,
        vpn: true,
        visitors: 90,
        total_pages: 450
      }
    ],
    session_duration: %{
      p25: 8,
      p50: 45,
      p75: 180,
      p90: 420,
      p95: 720,
      avg: 112.3,
      sessions_with_data: 8200
    },
    ip_rotation: %{
      rotating_3plus: 45,
      rotating_5plus: 12,
      total: 12500
    },
    pageview_thresholds: %{
      pv20: 380,
      pv50: 85,
      pv100: 22,
      pv200: 8,
      pv1000: 1,
      total: 12500
    },
    bounce_by_network: [
      %{datacenter: false, vpn: false, bounce_rate: 42.3, total_sessions: 15000, avg_pages: 3.2},
      %{datacenter: true, vpn: false, bounce_rate: 68.1, total_sessions: 420, avg_pages: 8.7},
      %{datacenter: false, vpn: true, bounce_rate: 45.0, total_sessions: 980, avg_pages: 2.9}
    ],
    vpn_providers: [
      %{name: "NordVPN", visitors: 320, avg_pages: 3.1},
      %{name: "ProtonVPN", visitors: 180, avg_pages: 2.8}
    ],
    resolutions: [
      %{resolution: "1920x1080", visitors: 3200, suspicious: false},
      %{resolution: "375x667", visitors: 1800, suspicious: false},
      %{resolution: "1440x900", visitors: 1200, suspicious: false},
      %{resolution: "412x915", visitors: 900, suspicious: false},
      %{resolution: "0x0", visitors: 45, suspicious: true}
    ],
    current_weights: Spectabas.Analytics.ScraperDetector.default_weights(),
    current_overrides: nil
  }

  describe "build_prompt/2 (via Module introspection)" do
    test "prompt builds without error for a typical site" do
      site = %Spectabas.Sites.Site{
        id: 1,
        name: "Test Site",
        domain: "b.example.com",
        scraper_content_prefixes: ["/listings/", "/breeds/"],
        scraper_weight_overrides: nil
      }

      # build_prompt is private, but we can test the full pipeline doesn't crash
      # by calling the module function that uses it indirectly.
      # Instead, we test the formatting helpers that are used in the prompt.
      prompt = build_prompt_via_send(site, @sample_baseline)

      assert is_binary(prompt)
      assert String.contains?(prompt, "Test Site")
      assert String.contains?(prompt, "b.example.com")
      assert String.contains?(prompt, "12500")
      assert String.contains?(prompt, "/listings/")
      assert String.contains?(prompt, "NordVPN")
      assert String.contains?(prompt, "AS14618")
      assert String.contains?(prompt, "datacenter_asn")
      assert String.contains?(prompt, "key_risks")
      assert String.contains?(prompt, "1920x1080")
      assert String.contains?(prompt, "375x667")
      assert String.contains?(prompt, "YES")
    end

    test "prompt handles empty data gracefully" do
      site = %Spectabas.Sites.Site{
        id: 2,
        name: "Empty Site",
        domain: "b.empty.com",
        scraper_content_prefixes: [],
        scraper_weight_overrides: nil
      }

      baseline = %{
        @sample_baseline
        | total_visitors: 0,
          devices: [],
          top_asns: [],
          bounce_by_network: [],
          vpn_providers: [],
          resolutions: []
      }

      prompt = build_prompt_via_send(site, baseline)

      assert String.contains?(prompt, "No device data available")
      assert String.contains?(prompt, "No ASN data available")
      assert String.contains?(prompt, "No VPN provider data")
      assert String.contains?(prompt, "No screen resolution data")
    end

    test "prompt includes overrides when present" do
      site = %Spectabas.Sites.Site{
        id: 3,
        name: "Override Site",
        domain: "b.override.com",
        scraper_content_prefixes: nil,
        scraper_weight_overrides: %{"datacenter_asn" => 20, "no_referrer" => 5}
      }

      prompt =
        build_prompt_via_send(site, %{
          @sample_baseline
          | current_overrides: site.scraper_weight_overrides
        })

      assert String.contains?(prompt, "Active Per-Site Weight Overrides")
      assert String.contains?(prompt, "REPLACE them entirely")
    end
  end

  describe "parse_ai_response/1" do
    test "parses clean JSON" do
      json = ~s({"weights": {"datacenter_asn": 30}, "confidence": "high"})
      result = parse_response_via_send(json)
      assert result["weights"]["datacenter_asn"] == 30
    end

    test "strips markdown code fences" do
      json = "```json\n{\"weights\": {\"datacenter_asn\": 25}}\n```"
      result = parse_response_via_send(json)
      assert result["weights"]["datacenter_asn"] == 25
    end

    test "returns error map for unparseable text" do
      result = parse_response_via_send("This is not JSON at all")
      assert result["error"] == "Failed to parse AI response"
    end
  end

  defp build_prompt_via_send(site, baseline) do
    ScraperCalibration.build_prompt(site, baseline)
  end

  defp parse_response_via_send(text) do
    ScraperCalibration.parse_ai_response(text)
  end
end
