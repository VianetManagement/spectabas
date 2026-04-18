defmodule Spectabas.Analytics.ScraperDetectorTest do
  use ExUnit.Case, async: true

  alias Spectabas.Analytics.ScraperDetector

  describe "score/1 — clean profile" do
    test "empty profile scores 10 (nil referrer is a scraper-lean hint)" do
      # Intentional: a visitor with NO data we can see is slightly scraper-lean.
      # Our only signal that fires with no data is :no_referrer (worth 10).
      assert %{score: 10, signals: [:no_referrer]} = ScraperDetector.score(%{})
    end

    test "normal residential visitor scores low" do
      profile = %{
        asn: "AS7922 COMCAST-7922",
        user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        visitor_ip_count: 1,
        session_pageviews: 8,
        page_paths: ["/", "/about", "/pricing"],
        content_path_prefixes: ["/listings"],
        referrer: "google.com",
        screen_resolution: "1920x1080",
        request_intervals_ms: [2400, 15_000, 8_200, 4_100, 22_000]
      }

      assert %{score: score, signals: []} = ScraperDetector.score(profile)
      assert score == 0
    end
  end

  describe "individual signals" do
    # Each test sets referrer: "google.com" to suppress the default
    # :no_referrer signal so we can assert one signal in isolation.

    test ":datacenter_asn fires on matching ASN prefix" do
      assert %{score: 40, signals: [:datacenter_asn]} =
               ScraperDetector.score(%{asn: "AS16276 OVH SAS", referrer: "google.com"})
    end

    test ":datacenter_asn does not fire for residential ISPs" do
      assert %{score: 0, signals: []} =
               ScraperDetector.score(%{asn: "AS7922 COMCAST-7922", referrer: "google.com"})
    end

    test ":spoofed_mobile_ua fires when mobile UA + datacenter ASN coincide" do
      result =
        ScraperDetector.score(%{
          asn: "AS16276 OVH SAS",
          user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ...",
          referrer: "google.com"
        })

      assert :datacenter_asn in result.signals
      assert :spoofed_mobile_ua in result.signals
      # 40 + 20 = 60
      assert result.score == 60
    end

    test ":spoofed_mobile_ua does NOT fire when mobile UA comes from a residential ASN" do
      result =
        ScraperDetector.score(%{
          asn: "AS7922 COMCAST-7922",
          user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
          referrer: "google.com"
        })

      refute :spoofed_mobile_ua in result.signals
      assert result.score == 0
    end

    test ":ip_rotation fires at 3+ IPs per visitor" do
      assert %{score: 20, signals: [:ip_rotation]} =
               ScraperDetector.score(%{visitor_ip_count: 3, referrer: "google.com"})

      assert %{score: 0, signals: []} =
               ScraperDetector.score(%{visitor_ip_count: 2, referrer: "google.com"})
    end

    test ":high_pageviews fires at 100+ unique pages with escalating thresholds" do
      # Under 100 — no pageview signal
      assert %{score: 0, signals: []} =
               ScraperDetector.score(%{session_pageviews: 50, referrer: "google.com"})

      # 100+ pages → +10
      assert %{score: 10, signals: [:high_pageviews]} =
               ScraperDetector.score(%{session_pageviews: 150, referrer: "google.com"})

      # 200+ pages → +15
      assert %{score: 15, signals: [:high_pageviews]} =
               ScraperDetector.score(%{session_pageviews: 300, referrer: "google.com"})

      # 500+ pages → +20
      assert %{score: 20, signals: [:high_pageviews]} =
               ScraperDetector.score(%{session_pageviews: 600, referrer: "google.com"})

      # 1000+ pages → +50
      assert %{score: 50, signals: [:extreme_pageviews]} =
               ScraperDetector.score(%{session_pageviews: 1500, referrer: "google.com"})
    end

    test ":systematic_crawl fires when >80% of paths match a content prefix" do
      paths = for i <- 1..10, do: "/listings/item-#{i}"

      assert %{score: 15, signals: [:systematic_crawl]} =
               ScraperDetector.score(%{
                 page_paths: paths,
                 content_path_prefixes: ["/listings"],
                 referrer: "google.com"
               })
    end

    test ":systematic_crawl does not fire when paths are mixed" do
      # 2 of 10 match → 20%, below threshold
      paths =
        Enum.map(1..8, fn i -> "/about-page-#{i}" end) ++
          ["/listings/one", "/listings/two"]

      assert %{score: 0, signals: []} =
               ScraperDetector.score(%{
                 page_paths: paths,
                 content_path_prefixes: ["/listings"],
                 referrer: "google.com"
               })
    end

    test ":systematic_crawl respects caller-supplied prefixes (different per site)" do
      paths = for i <- 1..10, do: "/profiles/user-#{i}"

      # With "/listings" prefix: no match
      assert %{signals: []} =
               ScraperDetector.score(%{
                 page_paths: paths,
                 content_path_prefixes: ["/listings"],
                 referrer: "google.com"
               })

      # With "/profiles" prefix: matches
      assert %{signals: [:systematic_crawl]} =
               ScraperDetector.score(%{
                 page_paths: paths,
                 content_path_prefixes: ["/profiles"],
                 referrer: "google.com"
               })
    end

    test ":no_referrer fires on nil or empty referrer" do
      assert %{score: 10, signals: [:no_referrer]} = ScraperDetector.score(%{referrer: nil})
      assert %{score: 10, signals: [:no_referrer]} = ScraperDetector.score(%{referrer: ""})
    end

    test ":no_referrer does not fire when referrer is present" do
      assert %{score: 0, signals: []} = ScraperDetector.score(%{referrer: "google.com"})
    end

    test ":robotic_timing fires when std dev of intervals is under 300ms" do
      intervals = [1200, 1210, 1195, 1205, 1198, 1202]

      assert %{score: 10, signals: [:robotic_timing]} =
               ScraperDetector.score(%{request_intervals_ms: intervals, referrer: "google.com"})
    end

    test ":robotic_timing does NOT fire on human-like variability" do
      intervals = [1200, 15_000, 400, 8_000, 22_000, 3_200]

      assert %{score: 0, signals: []} =
               ScraperDetector.score(%{request_intervals_ms: intervals, referrer: "google.com"})
    end

    test ":robotic_timing is skipped when fewer than 5 intervals" do
      intervals = [1200, 1210, 1195, 1205]

      assert %{score: 0, signals: []} =
               ScraperDetector.score(%{request_intervals_ms: intervals, referrer: "google.com"})
    end

    test ":suspicious_resolution fires for known headless defaults" do
      assert %{score: 5, signals: [:suspicious_resolution]} =
               ScraperDetector.score(%{screen_resolution: "800x600", referrer: "google.com"})

      assert %{score: 5, signals: [:suspicious_resolution]} =
               ScraperDetector.score(%{screen_resolution: "1024x768", referrer: "google.com"})
    end

    test ":suspicious_resolution does not fire for normal resolutions" do
      assert %{score: 0, signals: []} =
               ScraperDetector.score(%{screen_resolution: "1920x1080", referrer: "google.com"})
    end

    test ":square_resolution fires for square screens" do
      result = ScraperDetector.score(%{screen_resolution: "1024x1024", referrer: "google.com"})
      assert :square_resolution in result.signals
      assert result.score == 15
    end

    test ":square_resolution skips social crawler ASNs" do
      result =
        ScraperDetector.score(%{
          screen_resolution: "2000x2000",
          referrer: "google.com",
          asn: "AS32934 Facebook"
        })

      refute :square_resolution in result.signals
    end

    test ":stale_browser fires for old Chrome versions" do
      result =
        ScraperDetector.score(%{
          browser: "Chrome Mobile",
          browser_version: "58.0.3029.83",
          referrer: "google.com"
        })

      assert :stale_browser in result.signals
      assert result.score == 15
    end

    test ":stale_browser does not fire for current Chrome" do
      result =
        ScraperDetector.score(%{
          browser: "Chrome",
          browser_version: "146.0.0.0",
          referrer: "google.com"
        })

      refute :stale_browser in result.signals
    end

    test ":stale_browser does not fire for non-Chrome browsers" do
      result =
        ScraperDetector.score(%{
          browser: "Firefox",
          browser_version: "59.0",
          referrer: "google.com"
        })

      refute :stale_browser in result.signals
    end

    test ":resolution_device_mismatch fires for smartphone with desktop resolution" do
      result =
        ScraperDetector.score(%{
          device_type: "smartphone",
          screen_resolution: "1280x1024",
          referrer: "google.com"
        })

      assert :resolution_device_mismatch in result.signals
      assert result.score == 10
    end

    test ":resolution_device_mismatch does not fire for desktop with desktop resolution" do
      result =
        ScraperDetector.score(%{
          device_type: "desktop",
          screen_resolution: "1280x1024",
          referrer: "google.com"
        })

      refute :resolution_device_mismatch in result.signals
    end

    test ":resolution_device_mismatch does not fire for smartphone with mobile resolution" do
      result =
        ScraperDetector.score(%{
          device_type: "smartphone",
          screen_resolution: "414x896",
          referrer: "google.com"
        })

      refute :resolution_device_mismatch in result.signals
    end
  end

  describe "VPN suppression" do
    test "consumer VPN suppresses datacenter, spoofed_mobile, and ip_rotation" do
      result =
        ScraperDetector.score(%{
          asn: "AS54113 Fastly, Inc.",
          is_datacenter: true,
          is_vpn: true,
          vpn_provider: "Apple Private Relay (Fastly)",
          user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X)",
          visitor_ip_count: 20,
          session_pageviews: 250,
          referrer: nil
        })

      refute :datacenter_asn in result.signals
      refute :spoofed_mobile_ua in result.signals
      refute :ip_rotation in result.signals
      assert :high_pageviews in result.signals
      assert :no_referrer in result.signals
    end

    test "VPN on known datacenter ASN does NOT suppress datacenter signal" do
      result =
        ScraperDetector.score(%{
          asn: "AS16276 OVH SAS",
          is_datacenter: true,
          is_vpn: true,
          vpn_provider: "PublicVpnConfigs",
          user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
          visitor_ip_count: 8,
          session_pageviews: 300,
          referrer: nil
        })

      assert :datacenter_asn in result.signals
      assert :spoofed_mobile_ua in result.signals
      # ip_rotation still suppressed for all VPN
      refute :ip_rotation in result.signals
    end

    test "is_vpn flag alone triggers suppression even without vpn_provider name" do
      result =
        ScraperDetector.score(%{
          asn: "AS54113 Fastly, Inc.",
          is_datacenter: false,
          is_vpn: true,
          vpn_provider: "",
          visitor_ip_count: 10,
          session_pageviews: 50,
          referrer: "google.com"
        })

      refute :ip_rotation in result.signals
    end
  end

  describe "composite scoring" do
    test "OVH scraper profile scores >= 85" do
      intervals = Enum.map(1..50, fn _ -> 1200 + :rand.uniform(100) end)
      paths = for i <- 1..290, do: "/listings/item-#{i}"

      result =
        ScraperDetector.score(%{
          asn: "AS16276 OVH SAS",
          user_agent:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
          visitor_ip_count: 8,
          session_pageviews: 290,
          page_paths: paths,
          content_path_prefixes: ["/listings", "/premier"],
          referrer: nil,
          screen_resolution: "1024x768",
          request_intervals_ms: intervals
        })

      assert result.score >= 85,
             "expected >=85 for confirmed scraper profile, got #{result.score} with signals #{inspect(result.signals)}"

      assert :datacenter_asn in result.signals
      assert :spoofed_mobile_ua in result.signals
      assert :ip_rotation in result.signals
      assert :high_pageviews in result.signals
      assert :systematic_crawl in result.signals
      assert :no_referrer in result.signals
      assert :robotic_timing in result.signals
      assert :suspicious_resolution in result.signals
    end

    test "score caps at 100" do
      # All signals firing at max — the raw sum exceeds 100
      intervals = Enum.map(1..50, fn _ -> 1200 end)
      paths = for i <- 1..500, do: "/listings/item-#{i}"

      result =
        ScraperDetector.score(%{
          asn: "AS16276 OVH SAS",
          user_agent: "iPhone",
          visitor_ip_count: 20,
          session_pageviews: 500,
          page_paths: paths,
          content_path_prefixes: ["/listings"],
          referrer: nil,
          screen_resolution: "375x667",
          request_intervals_ms: intervals
        })

      assert result.score == 100
    end
  end

  describe "verdict/1" do
    test "0 is :normal" do
      assert ScraperDetector.verdict(0) == :normal
    end

    test "59 is :normal" do
      assert ScraperDetector.verdict(59) == :normal
    end

    test "60 is :suspicious (inclusive threshold)" do
      assert ScraperDetector.verdict(60) == :suspicious
    end

    test "84 is :suspicious" do
      assert ScraperDetector.verdict(84) == :suspicious
    end

    test "85 is :certain (inclusive threshold)" do
      assert ScraperDetector.verdict(85) == :certain
    end

    test "100 is :certain" do
      assert ScraperDetector.verdict(100) == :certain
    end
  end

  describe "public accessors" do
    test "datacenter_asns/0 returns a non-empty list of strings" do
      asns = ScraperDetector.datacenter_asns()
      assert is_list(asns) and asns != []
      assert Enum.all?(asns, &is_binary/1)
      assert "AS16276" in asns
    end

    test "suspicious_resolutions/0 returns a non-empty list of strings" do
      res = ScraperDetector.suspicious_resolutions()
      assert is_list(res) and res != []
      assert "800x600" in res
      assert "0x0" not in res
      assert "375x667" not in res
    end

    test "thresholds expose the documented values" do
      assert ScraperDetector.score_suspicious() == 60
      assert ScraperDetector.score_certain() == 85
    end
  end
end
