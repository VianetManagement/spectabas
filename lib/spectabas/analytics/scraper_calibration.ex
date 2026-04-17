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

    # Visitor behavioral distribution (last 30 days)
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
      WHERE site_id = #{site_p}
        AND timestamp >= now() - INTERVAL 30 DAY
        AND ip_is_bot = 0
      GROUP BY visitor_id
    )
    """

    # Network breakdown
    network_sql = """
    SELECT
      count(DISTINCT visitor_id) AS total,
      countDistinctIf(visitor_id, ip_is_datacenter = 1) AS datacenter_visitors,
      countDistinctIf(visitor_id, ip_is_vpn = 1) AS vpn_visitors,
      countDistinctIf(visitor_id, ip_is_datacenter = 0 AND ip_is_vpn = 0) AS residential_visitors
    FROM events
    WHERE site_id = #{site_p}
      AND timestamp >= now() - INTERVAL 30 DAY
      AND ip_is_bot = 0
    """

    # Referrer breakdown
    referrer_sql = """
    SELECT
      countDistinctIf(visitor_id, referrer_domain = '') AS direct_visitors,
      countDistinctIf(visitor_id, referrer_domain != '') AS referred_visitors
    FROM events
    WHERE site_id = #{site_p}
      AND timestamp >= now() - INTERVAL 30 DAY
      AND ip_is_bot = 0
      AND event_type = 'pageview'
    """

    with {:ok, [stats]} <- ClickHouse.query(stats_sql),
         {:ok, [network]} <- ClickHouse.query(network_sql),
         {:ok, [referrer]} <- ClickHouse.query(referrer_sql) do
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
      {provider, api_key, model} = Spectabas.AI.Config.credentials(site)
      prompt = build_prompt(site, baseline)

      ai_opts = %{provider: String.to_existing_atom(provider), api_key: api_key, model: model}

      case Completion.generate(ai_opts.provider, ai_opts, prompt) do
        {:ok, response} ->
          recommendations = parse_ai_response(response.text)

          {:ok,
           %{
             recommendations: recommendations,
             provider: provider,
             model: model || "",
             prompt_tokens: response[:prompt_tokens],
             completion_tokens: response[:completion_tokens]
           }}

        {:error, reason} ->
          {:error, "AI analysis failed: #{inspect(reason)}"}
      end
    end
  end

  defp build_prompt(site, baseline) do
    dist = baseline.pageview_distribution
    net = baseline.network
    ref = baseline.referrer
    weights = baseline.current_weights
    overrides = baseline.current_overrides

    """
    You are a web scraper detection expert. Analyze this site's visitor behavior and recommend signal weight adjustments for the scraper scoring model.

    ## Site: #{site.name} (#{site.domain})
    Period: Last 30 days
    Total visitors: #{baseline.total_visitors}

    ## Visitor Pageview Distribution (unique pages per visitor)
    - p50: #{dist.p50} pages
    - p75: #{dist.p75} pages
    - p90: #{dist.p90} pages
    - p95: #{dist.p95} pages
    - p99: #{dist.p99} pages
    - Average: #{Float.round(dist.avg, 1)} pages

    ## Network Breakdown
    - Datacenter IPs: #{net.datacenter} visitors (#{pct(net.datacenter, baseline.total_visitors)}%)
    - VPN users: #{net.vpn} visitors (#{pct(net.vpn, baseline.total_visitors)}%)
    - Residential: #{net.residential} visitors (#{pct(net.residential, baseline.total_visitors)}%)

    ## Referrer Breakdown
    - Direct (no referrer): #{ref.direct} visitors (#{pct(ref.direct, ref.direct + ref.referred)}%)
    - Referred: #{ref.referred} visitors

    ## Current Scoring Weights
    #{format_weights(weights)}

    #{if overrides, do: "## Current Per-Site Overrides\n#{format_weights(overrides)}", else: "No per-site overrides currently applied."}

    ## Scoring Tiers (used by webhook recipient)
    - Score 85+: Full countermeasures (tarpit + data poisoning)
    - Score 70-84: Tarpit only (slow responses)
    - Score 40-69: Watching (log only)
    - Score < 40: Not flagged

    ## Task
    Based on this site's behavioral data, recommend weight adjustments. Consider:
    1. If the p95 pageview count is high (e.g., 30+), the high_pageviews threshold may catch legitimate users
    2. If datacenter traffic is >5%, some may be legitimate (monitoring, APIs, corporate proxies)
    3. If direct traffic (no referrer) is >40%, the no_referrer signal has less discriminating power for this site

    Respond with ONLY a valid JSON object (no markdown, no code fences) with this structure:
    {
      "weights": {
        "datacenter_asn": <number>,
        "spoofed_mobile_ua": <number>,
        "ip_rotation": <number>,
        "very_high_pageviews_200": <number>,
        "very_high_pageviews_100": <number>,
        "high_pageviews_50": <number>,
        "high_pageviews_20": <number>,
        "systematic_crawl": <number>,
        "robotic_timing": <number>,
        "no_referrer": <number>,
        "suspicious_resolution": <number>
      },
      "reasoning": "<1-2 sentence explanation of each change>",
      "confidence": "<high|medium|low>",
      "warnings": "<any false-positive risks to watch for>"
    }
    """
  end

  defp format_weights(weights) when is_map(weights) do
    weights
    |> Enum.map(fn {k, v} -> "- #{k}: +#{v}" end)
    |> Enum.join("\n")
  end

  defp format_weights(_), do: "None"

  defp pct(_, 0), do: 0.0
  defp pct(n, total), do: Float.round(n / total * 100, 1)

  defp parse_ai_response(text) do
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
