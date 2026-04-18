defmodule Spectabas.Analytics.ScraperDetector do
  @moduledoc """
  Pure, stateless scoring for scraper-like traffic.

  `score/1` returns `%{score: integer, signals: [atom]}` for a visitor profile
  built from already-aggregated ClickHouse data. `verdict/1` maps a score to
  a categorical atom. No DB access, no HTTP, no side effects — this module
  can be called from the dashboard, from the collect pipeline, from an API,
  or from tests with equal ease.

  Input shape (all keys optional, all values nullable-safe):

      %{
        asn: "AS16276 OVH SAS",
        user_agent: "Mozilla/5.0 (iPhone; ...)",
        visitor_ip_count: 8,
        session_pageviews: 290,
        page_paths: ["/listings/abc", "/premier/x", ...],
        content_path_prefixes: ["/listings", "/premier"],
        referrer: nil,
        screen_resolution: "375x667",
        request_intervals_ms: [1200, 1180, 1210, ...]
      }

  `content_path_prefixes` is caller-supplied so the module can be reused
  across sites with different URL structures. If the list is empty or all
  provided `page_paths` are empty, the `:systematic_crawl` signal is skipped.
  """

  @datacenter_asns ~w(
    AS16276
    AS14061
    AS396982
    AS16509
    AS20473
    AS24940
    AS51167
    AS40021
    AS8100
    AS46844
    AS46941
    AS49981
    AS212238
    AS60068
    AS63023
    AS46475
    AS397423
    AS397391
    AS7393
    AS207990
    AS203020
    AS39486
  )

  @suspicious_resolutions ~w(
    800x600
    1024x768
  )

  # Social/platform crawler ASNs — exempt from square_resolution signal
  @social_crawler_asns ~w(
    AS32934
    AS63293
    AS13414
    AS15169
    AS36459
  )

  # Chrome major version threshold — anything below this is considered stale
  @stale_chrome_version 100

  @score_watching 40
  @score_suspicious 60
  @score_certain 85

  @doc "List of ASN prefixes classified as datacenter/hosting providers."
  def datacenter_asns, do: @datacenter_asns

  @doc "List of screen resolutions commonly used by headless browsers/emulators."
  def suspicious_resolutions, do: @suspicious_resolutions

  @doc "Score threshold for the watching tier (logged but no action)."
  def score_watching, do: @score_watching

  @doc "Score threshold at which a visitor is considered suspicious."
  def score_suspicious, do: @score_suspicious

  @doc "Score threshold at which a visitor is considered a near-certain scraper."
  def score_certain, do: @score_certain

  # Default signal weights
  # Pageview thresholds calibrated from 642k visitors (30d):
  #   p95=16, p99=47, p99.9=173, p99.99=388
  #   20-49 pages: 92% residential, 50-99: 90%, 100-199: 90%, 200-999: 84%, 1000+: 75% DC
  @default_weights %{
    datacenter_asn: 40,
    spoofed_mobile_ua: 20,
    ip_rotation: 20,
    extreme_pageviews_1000: 50,
    high_pageviews_500: 20,
    high_pageviews_200: 15,
    high_pageviews_100: 10,
    systematic_crawl: 15,
    robotic_timing: 10,
    no_referrer: 10,
    suspicious_resolution: 5,
    square_resolution: 15,
    stale_browser: 15,
    resolution_device_mismatch: 10
  }

  def default_weights, do: @default_weights

  @doc """
  Score a visitor profile. Returns `%{score: integer(0..100), signals: [atom]}`.
  Accepts optional per-site weight overrides map.
  """
  def score(profile, overrides \\ nil) when is_map(profile) do
    w = merge_weights(overrides)
    signals = []
    points = 0

    {points, signals} = add_datacenter_signal(points, signals, profile, w)
    {points, signals} = add_spoofed_ua_signal(points, signals, profile, w)
    {points, signals} = add_ip_rotation_signal(points, signals, profile, w)
    {points, signals} = add_pageview_signal(points, signals, profile, w)
    {points, signals} = add_systematic_crawl_signal(points, signals, profile, w)
    {points, signals} = add_referrer_signal(points, signals, profile, w)
    {points, signals} = add_robotic_timing_signal(points, signals, profile, w)
    {points, signals} = add_resolution_signal(points, signals, profile, w)
    {points, signals} = add_square_resolution_signal(points, signals, profile, w)
    {points, signals} = add_stale_browser_signal(points, signals, profile, w)
    {points, signals} = add_resolution_device_mismatch_signal(points, signals, profile, w)

    %{score: min(points, 100), signals: Enum.reverse(signals)}
  end

  @doc "Classify a score into a verdict atom."
  def verdict(score) when is_integer(score) do
    cond do
      score >= @score_certain -> :certain
      score >= @score_suspicious -> :suspicious
      true -> :normal
    end
  end

  # ---------------- Signal helpers ----------------

  defp add_datacenter_signal(points, signals, profile, w) do
    is_dc_asn = datacenter_asn?(profile[:asn])
    is_dc = is_dc_asn or profile[:is_datacenter] == true
    on_vpn = known_vpn_provider?(profile[:vpn_provider]) or profile[:is_vpn] == true

    # Suppress for VPN users unless they're on a KNOWN datacenter ASN.
    # This handles: VPN on OVH (still datacenter) vs iCloud Private Relay
    # on Akamai (not datacenter, is_datacenter=1 is stale data).
    suppressed = on_vpn and not is_dc_asn

    if is_dc and not suppressed do
      {points + w.datacenter_asn, [:datacenter_asn | signals]}
    else
      {points, signals}
    end
  end

  defp add_spoofed_ua_signal(points, signals, profile, w) do
    is_dc_asn = datacenter_asn?(profile[:asn])
    is_dc = is_dc_asn or profile[:is_datacenter] == true
    on_vpn = known_vpn_provider?(profile[:vpn_provider]) or profile[:is_vpn] == true
    suppressed = on_vpn and not is_dc_asn

    if is_dc and not suppressed and mobile_ua?(profile[:user_agent]) do
      {points + w.spoofed_mobile_ua, [:spoofed_mobile_ua | signals]}
    else
      {points, signals}
    end
  end

  defp add_ip_rotation_signal(points, signals, profile, w) do
    on_vpn = known_vpn_provider?(profile[:vpn_provider]) or profile[:is_vpn] == true

    case profile[:visitor_ip_count] do
      n when is_integer(n) and n >= 3 ->
        if on_vpn do
          # VPN/privacy relay users rotate IPs by design — not suspicious
          {points, signals}
        else
          {points + w.ip_rotation, [:ip_rotation | signals]}
        end

      _ ->
        {points, signals}
    end
  end

  defp add_pageview_signal(points, signals, profile, w) do
    case profile[:session_pageviews] do
      n when is_integer(n) and n >= 1000 ->
        {points + w.extreme_pageviews_1000, [:extreme_pageviews | signals]}

      n when is_integer(n) and n >= 500 ->
        {points + w.high_pageviews_500, [:high_pageviews | signals]}

      n when is_integer(n) and n >= 200 ->
        {points + w.high_pageviews_200, [:high_pageviews | signals]}

      n when is_integer(n) and n >= 100 ->
        {points + w.high_pageviews_100, [:high_pageviews | signals]}

      _ ->
        {points, signals}
    end
  end

  defp add_systematic_crawl_signal(points, signals, profile, w) do
    paths = List.wrap(profile[:page_paths])
    prefixes = List.wrap(profile[:content_path_prefixes])

    if paths != [] and prefixes != [] do
      matching = Enum.count(paths, &path_matches_any?(&1, prefixes))
      ratio = matching / length(paths)

      if ratio > 0.8 do
        {points + w.systematic_crawl, [:systematic_crawl | signals]}
      else
        {points, signals}
      end
    else
      {points, signals}
    end
  end

  defp add_referrer_signal(points, signals, profile, w) do
    case profile[:referrer] do
      nil -> {points + w.no_referrer, [:no_referrer | signals]}
      "" -> {points + w.no_referrer, [:no_referrer | signals]}
      _ -> {points, signals}
    end
  end

  defp add_robotic_timing_signal(points, signals, profile, w) do
    intervals = profile[:request_intervals_ms]

    case intervals do
      list when is_list(list) and length(list) >= 5 ->
        sd = std_dev(list)

        if sd < 300.0 do
          {points + w.robotic_timing, [:robotic_timing | signals]}
        else
          {points, signals}
        end

      _ ->
        {points, signals}
    end
  end

  defp add_resolution_signal(points, signals, profile, w) do
    if (profile[:screen_resolution] || "") in @suspicious_resolutions do
      {points + w.suspicious_resolution, [:suspicious_resolution | signals]}
    else
      {points, signals}
    end
  end

  defp add_square_resolution_signal(points, signals, profile, w) do
    res = profile[:screen_resolution] || ""

    case String.split(res, "x") do
      [w_str, h_str] ->
        width = String.to_integer(w_str)
        height = String.to_integer(h_str)

        if width == height and width > 0 and not social_crawler_asn?(profile[:asn]) do
          {points + w.square_resolution, [:square_resolution | signals]}
        else
          {points, signals}
        end

      _ ->
        {points, signals}
    end
  rescue
    _ -> {points, signals}
  end

  defp add_stale_browser_signal(points, signals, profile, w) do
    browser = profile[:browser] || ""
    version = profile[:browser_version] || ""

    if String.contains?(browser, "Chrome") do
      major = version |> String.split(".") |> List.first() |> to_integer_safe()

      if major > 0 and major < @stale_chrome_version do
        {points + w.stale_browser, [:stale_browser | signals]}
      else
        {points, signals}
      end
    else
      {points, signals}
    end
  end

  defp add_resolution_device_mismatch_signal(points, signals, profile, w) do
    device = profile[:device_type] || ""
    res = profile[:screen_resolution] || ""

    case String.split(res, "x") do
      [w_str, _h_str] ->
        width = String.to_integer(w_str)

        if device == "smartphone" and width >= 1024 do
          {points + w.resolution_device_mismatch, [:resolution_device_mismatch | signals]}
        else
          {points, signals}
        end

      _ ->
        {points, signals}
    end
  rescue
    _ -> {points, signals}
  end

  # ---------------- Predicates ----------------

  defp social_crawler_asn?(nil), do: false

  defp social_crawler_asn?(asn) when is_binary(asn) do
    Enum.any?(@social_crawler_asns, fn prefix -> String.starts_with?(asn, prefix) end)
  end

  defp social_crawler_asn?(_), do: false

  defp to_integer_safe(nil), do: 0
  defp to_integer_safe(""), do: 0

  defp to_integer_safe(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp to_integer_safe(_), do: 0

  defp datacenter_asn?(nil), do: false

  defp datacenter_asn?(asn) when is_binary(asn) do
    Enum.any?(@datacenter_asns, fn prefix ->
      String.starts_with?(asn, prefix)
    end)
  end

  defp datacenter_asn?(_), do: false

  defp mobile_ua?(nil), do: false

  defp mobile_ua?(ua) when is_binary(ua) do
    ua_lower = String.downcase(ua)

    String.contains?(ua_lower, "iphone") or
      String.contains?(ua_lower, "android") or
      String.contains?(ua_lower, "mobile")
  end

  defp mobile_ua?(_), do: false

  defp path_matches_any?(path, prefixes) when is_binary(path) do
    Enum.any?(prefixes, fn prefix ->
      is_binary(prefix) and String.starts_with?(path, prefix)
    end)
  end

  defp path_matches_any?(_, _), do: false

  # ---------------- Math ----------------

  # Population standard deviation. Inline — no external math lib.
  defp std_dev(list) when is_list(list) and list != [] do
    nums =
      list
      |> Enum.map(fn
        n when is_number(n) -> n * 1.0
        _ -> 0.0
      end)

    n = length(nums)
    mean = Enum.sum(nums) / n
    variance = Enum.reduce(nums, 0.0, fn x, acc -> acc + :math.pow(x - mean, 2) end) / n
    :math.sqrt(variance)
  end

  defp std_dev(_), do: 0.0

  defp known_vpn_provider?(nil), do: false
  defp known_vpn_provider?(""), do: false
  defp known_vpn_provider?(name) when is_binary(name), do: true
  defp known_vpn_provider?(_), do: false

  # Merge per-site overrides into default weights. Overrides is a map with
  # string keys (from JSON) like %{"datacenter_asn" => 45, "no_referrer" => 15}.
  defp merge_weights(nil), do: @default_weights

  defp merge_weights(overrides) when is_map(overrides) do
    Enum.reduce(overrides, @default_weights, fn {key, value}, acc ->
      atom_key =
        try do
          String.to_existing_atom(key)
        rescue
          _ -> nil
        end

      if atom_key && Map.has_key?(acc, atom_key) && is_number(value) do
        Map.put(acc, atom_key, value)
      else
        acc
      end
    end)
  end

  defp merge_weights(_), do: @default_weights
end
