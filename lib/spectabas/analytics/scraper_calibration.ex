defmodule Spectabas.Analytics.ScraperCalibration do
  require Logger

  alias Spectabas.{Repo, ClickHouse, Sites}
  alias Spectabas.Analytics.ScraperDetector
  alias Spectabas.AI.Completion
  import Spectabas.TypeHelpers

  defmodule Result do
    use Ecto.Schema
    import Ecto.Changeset

    schema "scraper_calibrations" do
      belongs_to :site, Spectabas.Sites.Site
      field :status, :string, default: "pending"
      field :baseline, :map
      field :recommendations, :map
      field :ai_provider, :string
      field :ai_model, :string
      field :prompt_tokens, :integer
      field :completion_tokens, :integer

      timestamps(type: :utc_datetime)
    end

    def changeset(result, attrs) do
      result
      |> cast(attrs, [
        :site_id,
        :status,
        :baseline,
        :recommendations,
        :ai_provider,
        :ai_model,
        :prompt_tokens,
        :completion_tokens
      ])
      |> validate_required([:site_id, :status])
      |> validate_inclusion(:status, ["pending", "approved", "rejected"])
    end
  end

  def run(%Sites.Site{} = site) do
    Logger.notice("[ScraperCalibration] Starting for site=#{site.id}")

    with {:ok, baseline} <- gather_baseline(site),
         {:ok, ai_result} <- analyze_with_ai(site, baseline) do
      %Result{}
      |> Result.changeset(%{
        site_id: site.id,
        status: "pending",
        baseline: baseline,
        recommendations: ai_result.recommendations,
        ai_provider: ai_result.provider,
        ai_model: ai_result.model,
        prompt_tokens: ai_result.prompt_tokens,
        completion_tokens: ai_result.completion_tokens
      })
      |> Repo.insert()
    end
  end

  def approve_calibration(calibration_id) do
    cal = Repo.get!(Result, calibration_id)
    site = Sites.get_site!(cal.site_id)
    weights = cal.recommendations["weights"] || %{}

    with {:ok, _site} <- Sites.update_site(site, %{"scraper_weight_overrides" => weights}),
         {:ok, cal} <- cal |> Result.changeset(%{status: "approved"}) |> Repo.update() do
      Logger.notice("[ScraperCalibration] Approved calibration #{cal.id} for site=#{site.id}")
      {:ok, cal}
    end
  end

  def reject_calibration(calibration_id) do
    Repo.get!(Result, calibration_id)
    |> Result.changeset(%{status: "rejected"})
    |> Repo.update()
  end

  def latest_for_site(site_id) do
    import Ecto.Query

    from(c in Result,
      where: c.site_id == ^site_id,
      order_by: [desc: c.inserted_at],
      limit: 5
    )
    |> Repo.all()
  end

  # --- Baseline gathering ---

  defp gather_baseline(site) do
    site_p = ClickHouse.param(site.id)
    base_where = "site_id = #{site_p} AND timestamp >= now() - INTERVAL 30 DAY AND ip_is_bot = 0"

    # 1. Visitor behavioral distribution
    stats_sql = """
    SELECT
      count(DISTINCT visitor_id) AS total_visitors,
      quantile(0.50)(pv) AS p50_pages,
      quantile(0.75)(pv) AS p75_pages,
      quantile(0.90)(pv) AS p90_pages,
      quantile(0.95)(pv) AS p95_pages,
      quantile(0.99)(pv) AS p99_pages,
      avg(pv) AS avg_pages
    FROM (
      SELECT visitor_id, uniqIf(url_path, event_type = 'pageview') AS pv
      FROM events
      WHERE #{base_where}
      GROUP BY visitor_id
    )
    """

    # 2. Network breakdown
    network_sql = """
    SELECT
      count(DISTINCT visitor_id) AS total,
      countDistinctIf(visitor_id, ip_is_datacenter = 1) AS datacenter_visitors,
      countDistinctIf(visitor_id, ip_is_vpn = 1) AS vpn_visitors,
      countDistinctIf(visitor_id, ip_is_datacenter = 0 AND ip_is_vpn = 0) AS residential_visitors
    FROM events
    WHERE #{base_where}
    """

    # 3. Referrer breakdown
    referrer_sql = """
    SELECT
      countDistinctIf(visitor_id, referrer_domain = '') AS direct_visitors,
      countDistinctIf(visitor_id, referrer_domain != '') AS referred_visitors
    FROM events
    WHERE #{base_where} AND event_type = 'pageview'
    """

    # 4. Device type breakdown (for spoofed_mobile_ua signal calibration)
    device_sql = """
    SELECT
      device_type,
      count(DISTINCT visitor_id) AS visitors
    FROM events
    WHERE #{base_where} AND event_type = 'pageview' AND device_type != ''
    GROUP BY device_type
    ORDER BY visitors DESC
    """

    # 5. Top ASNs by visitor count (shows which networks are actually sending traffic)
    asn_sql = """
    SELECT
      ip_asn,
      ip_asn_org,
      ip_is_datacenter,
      ip_is_vpn,
      count(DISTINCT visitor_id) AS visitors,
      uniqIf(url_path, event_type = 'pageview') AS total_pages
    FROM events
    WHERE #{base_where} AND ip_asn > 0
    GROUP BY ip_asn, ip_asn_org, ip_is_datacenter, ip_is_vpn
    ORDER BY visitors DESC
    LIMIT 20
    """

    # 6. Session duration distribution (bots tend to have very short or very long sessions)
    session_sql = """
    SELECT
      quantile(0.25)(dur) AS p25_duration,
      quantile(0.50)(dur) AS p50_duration,
      quantile(0.75)(dur) AS p75_duration,
      quantile(0.90)(dur) AS p90_duration,
      quantile(0.95)(dur) AS p95_duration,
      avg(dur) AS avg_duration
    FROM (
      SELECT session_id, max(duration_s) AS dur
      FROM events
      WHERE #{base_where} AND event_type = 'pageview' AND session_id != ''
      GROUP BY session_id
    )
    """

    # 7. IP rotation — visitors with multiple IPs (the ip_rotation signal trigger)
    rotation_sql = """
    SELECT
      countDistinctIf(visitor_id, ip_count >= 3) AS rotating_visitors,
      countDistinctIf(visitor_id, ip_count >= 5) AS heavy_rotating,
      count(DISTINCT visitor_id) AS total_visitors
    FROM (
      SELECT visitor_id, uniq(ip_address) AS ip_count
      FROM events
      WHERE #{base_where}
      GROUP BY visitor_id
    )
    """

    # 8. Current scraper score distribution (what the model is actually flagging right now)
    # Uses a simplified scoring approach: count visitors by signal-relevant behaviors
    flagged_sql = """
    SELECT
      countDistinctIf(visitor_id, pv >= 20) AS pv20_visitors,
      countDistinctIf(visitor_id, pv >= 50) AS pv50_visitors,
      countDistinctIf(visitor_id, pv >= 100) AS pv100_visitors,
      countDistinctIf(visitor_id, pv >= 200) AS pv200_visitors,
      countDistinctIf(visitor_id, pv >= 1000) AS pv1000_visitors,
      count(DISTINCT visitor_id) AS total
    FROM (
      SELECT visitor_id, uniqIf(url_path, event_type = 'pageview') AS pv
      FROM events
      WHERE #{base_where}
      GROUP BY visitor_id
    )
    """

    # 9. Bounce rate by network type (datacenter bouncers vs engaged datacenter visitors)
    bounce_sql = """
    SELECT
      ip_is_datacenter,
      ip_is_vpn,
      countIf(pv = 1) AS single_page_sessions,
      count(*) AS total_sessions,
      avg(pv) AS avg_pages_per_session
    FROM (
      SELECT session_id, ip_is_datacenter, ip_is_vpn,
             uniqIf(url_path, event_type = 'pageview') AS pv
      FROM events
      WHERE #{base_where} AND session_id != ''
      GROUP BY session_id, ip_is_datacenter, ip_is_vpn
    )
    GROUP BY ip_is_datacenter, ip_is_vpn
    """

    # 10. VPN provider breakdown
    vpn_sql = """
    SELECT
      ip_vpn_provider,
      count(DISTINCT visitor_id) AS visitors,
      avg(pv) AS avg_pages
    FROM (
      SELECT visitor_id, ip_vpn_provider, uniqIf(url_path, event_type = 'pageview') AS pv
      FROM events
      WHERE #{base_where} AND ip_is_vpn = 1 AND ip_vpn_provider != ''
      GROUP BY visitor_id, ip_vpn_provider
    )
    GROUP BY ip_vpn_provider
    ORDER BY visitors DESC
    LIMIT 15
    """

    with {:ok, [stats]} <- ClickHouse.query(stats_sql),
         {:ok, [network]} <- ClickHouse.query(network_sql),
         {:ok, [referrer]} <- ClickHouse.query(referrer_sql),
         {:ok, devices} <- ClickHouse.query(device_sql),
         {:ok, asns} <- ClickHouse.query(asn_sql),
         {:ok, [session]} <- ClickHouse.query(session_sql),
         {:ok, [rotation]} <- ClickHouse.query(rotation_sql),
         {:ok, [flagged]} <- ClickHouse.query(flagged_sql),
         {:ok, bounces} <- ClickHouse.query(bounce_sql),
         {:ok, vpns} <- ClickHouse.query(vpn_sql) do
      {:ok,
       %{
         total_visitors: to_num(stats["total_visitors"]),
         pageview_distribution: %{
           p50: to_num(stats["p50_pages"]),
           p75: to_num(stats["p75_pages"]),
           p90: to_num(stats["p90_pages"]),
           p95: to_num(stats["p95_pages"]),
           p99: to_num(stats["p99_pages"]),
           avg: to_float(stats["avg_pages"])
         },
         network: %{
           datacenter: to_num(network["datacenter_visitors"]),
           vpn: to_num(network["vpn_visitors"]),
           residential: to_num(network["residential_visitors"])
         },
         referrer: %{
           direct: to_num(referrer["direct_visitors"]),
           referred: to_num(referrer["referred_visitors"])
         },
         devices:
           Enum.map(devices, fn d ->
             %{type: d["device_type"], visitors: to_num(d["visitors"])}
           end),
         top_asns:
           Enum.map(asns, fn a ->
             %{
               asn: "AS#{a["ip_asn"]}",
               org: a["ip_asn_org"] || "",
               datacenter: to_num(a["ip_is_datacenter"]) == 1,
               vpn: to_num(a["ip_is_vpn"]) == 1,
               visitors: to_num(a["visitors"]),
               total_pages: to_num(a["total_pages"])
             }
           end),
         session_duration: %{
           p25: to_num(session["p25_duration"]),
           p50: to_num(session["p50_duration"]),
           p75: to_num(session["p75_duration"]),
           p90: to_num(session["p90_duration"]),
           p95: to_num(session["p95_duration"]),
           avg: to_float(session["avg_duration"])
         },
         ip_rotation: %{
           rotating_3plus: to_num(rotation["rotating_visitors"]),
           rotating_5plus: to_num(rotation["heavy_rotating"]),
           total: to_num(rotation["total_visitors"])
         },
         pageview_thresholds: %{
           pv20: to_num(flagged["pv20_visitors"]),
           pv50: to_num(flagged["pv50_visitors"]),
           pv100: to_num(flagged["pv100_visitors"]),
           pv200: to_num(flagged["pv200_visitors"]),
           pv1000: to_num(flagged["pv1000_visitors"]),
           total: to_num(flagged["total"])
         },
         bounce_by_network:
           Enum.map(bounces, fn b ->
             %{
               datacenter: to_num(b["ip_is_datacenter"]) == 1,
               vpn: to_num(b["ip_is_vpn"]) == 1,
               bounce_rate:
                 safe_pct(to_num(b["single_page_sessions"]), to_num(b["total_sessions"])),
               total_sessions: to_num(b["total_sessions"]),
               avg_pages: to_float(b["avg_pages_per_session"])
             }
           end),
         vpn_providers:
           Enum.map(vpns, fn v ->
             %{
               name: v["ip_vpn_provider"],
               visitors: to_num(v["visitors"]),
               avg_pages: to_float(v["avg_pages"])
             }
           end),
         current_weights: ScraperDetector.default_weights(),
         current_overrides: site.scraper_weight_overrides
       }}
    end
  end

  # --- AI analysis ---

  defp analyze_with_ai(site, baseline) do
    if !Spectabas.AI.Config.configured?(site) do
      {:error,
       "No AI provider configured for this site. Set up AI in Settings > Content > AI Analysis."}
    else
      {provider, _api_key, model} = Spectabas.AI.Config.credentials(site)
      prompt = build_prompt(site, baseline)

      case Completion.generate(site, "", prompt, max_tokens: 4096) do
        {:ok, text} ->
          recommendations = parse_ai_response(text)

          {:ok,
           %{
             recommendations: recommendations,
             provider: provider,
             model: model || "",
             prompt_tokens: nil,
             completion_tokens: nil
           }}

        {:error, reason} ->
          {:error, "AI analysis failed: #{inspect(reason)}"}
      end
    end
  end

  @doc false
  def build_prompt(site, baseline) do
    dist = baseline.pageview_distribution
    net = baseline.network
    ref = baseline.referrer
    dur = baseline.session_duration
    rot = baseline.ip_rotation
    pv_thresh = baseline.pageview_thresholds
    weights = baseline.current_weights
    overrides = baseline.current_overrides

    """
    You are a senior web scraper detection engineer performing a forensic analysis of a site's traffic patterns. Your task is to calibrate signal weights for a scraper scoring model. This matters because miscalibrated weights either miss real scrapers (data theft, cost) or flag legitimate users (lost business).

    Think step-by-step through each signal. For every weight you recommend, show your reasoning chain: what the data shows → what that implies about this site's traffic → whether the default weight is appropriate → your adjusted value and why.

    ## Site Profile
    - Name: #{site.name}
    - Analytics domain: #{site.domain}
    - Period: Last 30 days
    - Total unique visitors: #{baseline.total_visitors}
    #{if site.scraper_content_prefixes && site.scraper_content_prefixes != [], do: "- Content path prefixes (for systematic crawl detection): #{Enum.join(site.scraper_content_prefixes, ", ")}", else: "- No content path prefixes configured (systematic_crawl signal has no prefixes to match against)"}

    ## 1. Pageview Distribution (unique pages per visitor)
    This is critical for calibrating the high_pageviews thresholds. If legitimate power users regularly hit 50+ pages, the thresholds need raising.

    | Percentile | Unique pages |
    |-----------|-------------|
    | p50 | #{dist.p50} |
    | p75 | #{dist.p75} |
    | p90 | #{dist.p90} |
    | p95 | #{dist.p95} |
    | p99 | #{dist.p99} |
    | Average | #{Float.round(dist.avg, 1)} |

    Visitors exceeding each pageview threshold:
    - 20+ pages: #{pv_thresh.pv20} visitors (#{pct(pv_thresh.pv20, pv_thresh.total)}% of all visitors)
    - 50+ pages: #{pv_thresh.pv50} visitors (#{pct(pv_thresh.pv50, pv_thresh.total)}%)
    - 100+ pages: #{pv_thresh.pv100} visitors (#{pct(pv_thresh.pv100, pv_thresh.total)}%)
    - 200+ pages: #{pv_thresh.pv200} visitors (#{pct(pv_thresh.pv200, pv_thresh.total)}%)
    - 1000+ pages: #{pv_thresh.pv1000} visitors (#{pct(pv_thresh.pv1000, pv_thresh.total)}%)

    KEY QUESTION: What percentage of the 20+ page visitors are likely legitimate power users vs scrapers? If p95 is already near 20, many real users are crossing that threshold.

    ## 2. Session Duration Distribution
    Short sessions (<5s) with many pageviews = bot. Long sessions with proportional pageviews = human. Zero-duration single-page visits = bounces (normal).

    | Percentile | Duration (seconds) |
    |-----------|-------------------|
    | p25 | #{dur.p25} |
    | p50 | #{dur.p50} |
    | p75 | #{dur.p75} |
    | p90 | #{dur.p90} |
    | p95 | #{dur.p95} |
    | Average | #{Float.round(dur.avg, 1)} |

    ## 3. Network Breakdown
    | Network type | Visitors | % of total |
    |-------------|---------|-----------|
    | Residential | #{net.residential} | #{pct(net.residential, baseline.total_visitors)}% |
    | Datacenter | #{net.datacenter} | #{pct(net.datacenter, baseline.total_visitors)}% |
    | VPN | #{net.vpn} | #{pct(net.vpn, baseline.total_visitors)}% |

    #{format_bounce_by_network(baseline.bounce_by_network)}

    KEY QUESTION: Are datacenter visitors bouncing at a higher rate than residential? If datacenter visitors have similar engagement to residential, the datacenter_asn weight may be too aggressive. If they bounce 2x+ more, the weight is justified.

    ## 4. Top ASNs (networks sending the most visitors)
    #{format_top_asns(baseline.top_asns)}

    Look for: datacenter ASNs with high page counts (likely scrapers), VPN ASNs with normal engagement (likely legitimate), residential ASNs that dominate traffic (baseline behavior).

    ## 5. Device Type Breakdown
    #{format_devices(baseline.devices)}

    The spoofed_mobile_ua signal fires when a mobile User-Agent comes from a datacenter IP. If this site has very low mobile traffic, a mobile UA from a datacenter is more suspicious. If mobile is 50%+ of traffic, the signal is less discriminating.

    ## 6. IP Rotation
    - Visitors using 3+ IPs: #{rot.rotating_3plus} (#{pct(rot.rotating_3plus, rot.total)}% of visitors)
    - Visitors using 5+ IPs: #{rot.rotating_5plus} (#{pct(rot.rotating_5plus, rot.total)}%)

    The ip_rotation signal fires at 3+ IPs. Consider: VPN users may rotate IPs legitimately. Mobile users switch between WiFi and cellular. If the rotation rate is high, this signal may need dampening.

    ## 7. Referrer Breakdown
    - Direct (no referrer): #{ref.direct} visitors (#{pct(ref.direct, ref.direct + ref.referred)}%)
    - Referred: #{ref.referred} visitors (#{pct(ref.referred, ref.direct + ref.referred)}%)

    The no_referrer signal adds weight when a visitor has no referrer. If >40% of this site's real traffic is direct, this signal has weak discriminating power and should be reduced. If <10% is direct, a missing referrer is more suspicious.

    ## 8. VPN Provider Breakdown
    #{format_vpn_providers(baseline.vpn_providers)}

    VPN suppression: The scoring model already suppresses datacenter_asn and spoofed_mobile_ua signals for visitors on known consumer VPN providers (NordVPN, ProtonVPN, etc). This section shows whether VPN users behave like real users or scrapers.

    ## Current Scoring Model

    ### Default Signal Weights
    #{format_weights(weights)}

    ### How Signals Combine
    - Signals are additive: a visitor hitting datacenter_asn (40) + spoofed_mobile_ua (20) + high_pageviews_20 (10) = score 70 (suspicious tier)
    - Score is capped at 100
    - Tiers determine automated response:
      * Score 85-100 (Certain): Full countermeasures deployed (tarpit + data poisoning)
      * Score 70-84 (Suspicious): Tarpit only (slow responses)
      * Score 40-69 (Watching): Logged, webhook fired, no automated action
      * Score < 40: Not flagged

    #{if overrides, do: "### Active Per-Site Weight Overrides\n#{format_weights(overrides)}\nThese overrides are currently in effect. Your recommendations will REPLACE them entirely.", else: "No per-site overrides currently applied."}

    ## Analysis Instructions

    For EACH of the 12 signals, provide:
    1. What the data tells you about this signal's relevance to this specific site
    2. Whether the default weight is too high (false positives), too low (missed scrapers), or appropriate
    3. Your recommended weight (0 to disable the signal entirely, or any positive integer)
    4. Your confidence in this specific recommendation (high/medium/low) and why

    Think carefully about signal interactions:
    - datacenter_asn (40) + spoofed_mobile_ua (20) = 60, which alone puts a visitor in the watching tier. Is that appropriate for this site?
    - A power user hitting 50+ pages from residential IP with a referrer shouldn't be penalized. But 50+ pages from a datacenter with no referrer is 65 points. Check if this matches the site's actual patterns.
    - If the site has very few visitors, statistical conclusions are weaker. Note when sample size limits confidence.

    ## Response Format

    IMPORTANT: Keep reasoning to 1-2 sentences per signal. The response must be compact enough to fit within output token limits.

    Respond with ONLY a valid JSON object (no markdown fences, no commentary outside the JSON). Put the weights object FIRST since it is the most critical output:
    {
      "weights": {
        "datacenter_asn": <n>,
        "spoofed_mobile_ua": <n>,
        "ip_rotation": <n>,
        "extreme_pageviews_1000": <n>,
        "very_high_pageviews_200": <n>,
        "very_high_pageviews_100": <n>,
        "high_pageviews_50": <n>,
        "high_pageviews_20": <n>,
        "systematic_crawl": <n>,
        "robotic_timing": <n>,
        "no_referrer": <n>,
        "suspicious_resolution": <n>
      },
      "reasoning": {
        "datacenter_asn": "<1-2 sentences>",
        "spoofed_mobile_ua": "<1-2 sentences>",
        "ip_rotation": "<1-2 sentences>",
        "extreme_pageviews_1000": "<1-2 sentences>",
        "very_high_pageviews_200": "<1-2 sentences>",
        "very_high_pageviews_100": "<1-2 sentences>",
        "high_pageviews_50": "<1-2 sentences>",
        "high_pageviews_20": "<1-2 sentences>",
        "systematic_crawl": "<1-2 sentences>",
        "robotic_timing": "<1-2 sentences>",
        "no_referrer": "<1-2 sentences>",
        "suspicious_resolution": "<1-2 sentences>"
      },
      "overall_confidence": "<high|medium|low>",
      "key_risks": ["<risk 1>", "<risk 2>", "<risk 3>"]
    }
    """
  end

  defp format_weights(weights) when is_map(weights) do
    weights
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.map(fn {k, v} -> "- #{k}: +#{v}" end)
    |> Enum.join("\n")
  end

  defp format_weights(_), do: "None"

  defp format_devices(devices) do
    if devices == [] do
      "No device data available."
    else
      total = Enum.reduce(devices, 0, fn d, acc -> acc + d.visitors end)

      header = "| Device | Visitors | % |\n|--------|---------|---|\n"

      rows =
        Enum.map(devices, fn d ->
          "| #{d.type} | #{d.visitors} | #{pct(d.visitors, total)}% |"
        end)
        |> Enum.join("\n")

      header <> rows
    end
  end

  defp format_top_asns(asns) do
    if asns == [] do
      "No ASN data available."
    else
      header =
        "| ASN | Organization | Type | Visitors | Total pages |\n|-----|-------------|------|---------|------------|\n"

      rows =
        Enum.map(asns, fn a ->
          type =
            cond do
              a.datacenter and a.vpn -> "DC+VPN"
              a.datacenter -> "Datacenter"
              a.vpn -> "VPN"
              true -> "Residential"
            end

          org = if a.org != "", do: a.org, else: "Unknown"
          "| #{a.asn} | #{org} | #{type} | #{a.visitors} | #{a.total_pages} |"
        end)
        |> Enum.join("\n")

      header <> rows
    end
  end

  defp format_bounce_by_network(bounces) do
    if bounces == [] do
      "No bounce data by network type available."
    else
      header =
        "### Bounce Rate & Engagement by Network Type\n| Network | Sessions | Bounce rate | Avg pages/session |\n|---------|---------|------------|------------------|\n"

      rows =
        Enum.map(bounces, fn b ->
          type =
            cond do
              b.datacenter and b.vpn -> "DC+VPN"
              b.datacenter -> "Datacenter"
              b.vpn -> "VPN"
              true -> "Residential"
            end

          "| #{type} | #{b.total_sessions} | #{b.bounce_rate}% | #{Float.round(b.avg_pages, 1)} |"
        end)
        |> Enum.join("\n")

      header <> rows
    end
  end

  defp format_vpn_providers(vpns) do
    if vpns == [] do
      "No VPN provider data available (no VPN traffic detected)."
    else
      header = "| Provider | Visitors | Avg pages |\n|----------|---------|----------|\n"

      rows =
        Enum.map(vpns, fn v ->
          "| #{v.name} | #{v.visitors} | #{Float.round(v.avg_pages, 1)} |"
        end)
        |> Enum.join("\n")

      header <> rows
    end
  end

  defp pct(_, 0), do: 0.0
  defp pct(n, total), do: Float.round(n / total * 100, 1)

  defp safe_pct(_, 0), do: 0.0
  defp safe_pct(n, total), do: Float.round(n / total * 100, 1)

  @doc false
  def parse_ai_response(text) do
    # Strip markdown code fences if present
    cleaned =
      text
      |> String.replace(~r/```json\s*/i, "")
      |> String.replace(~r/```\s*/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{"error" => "Failed to parse AI response", "raw" => String.slice(text, 0, 500)}
    end
  end
end
