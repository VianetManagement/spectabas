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
    AS63949
    AS20473
    AS24940
    AS51167
    AS8100
    AS46844
  )

  @suspicious_resolutions ~w(
    375x667
    375x812
    412x915
    360x640
    800x600
    1024x768
    0x0
  )

  @score_suspicious 60
  @score_certain 85

  @doc "List of ASN prefixes classified as datacenter/hosting providers."
  def datacenter_asns, do: @datacenter_asns

  @doc "List of screen resolutions commonly used by headless browsers/emulators."
  def suspicious_resolutions, do: @suspicious_resolutions

  @doc "Score threshold at which a visitor is considered suspicious."
  def score_suspicious, do: @score_suspicious

  @doc "Score threshold at which a visitor is considered a near-certain scraper."
  def score_certain, do: @score_certain

  @doc """
  Score a visitor profile. Returns `%{score: integer(0..100), signals: [atom]}`.
  """
  def score(profile) when is_map(profile) do
    signals = []
    points = 0

    {points, signals} = add_datacenter_signal(points, signals, profile)
    {points, signals} = add_spoofed_ua_signal(points, signals, profile)
    {points, signals} = add_ip_rotation_signal(points, signals, profile)
    {points, signals} = add_pageview_signal(points, signals, profile)
    {points, signals} = add_systematic_crawl_signal(points, signals, profile)
    {points, signals} = add_referrer_signal(points, signals, profile)
    {points, signals} = add_robotic_timing_signal(points, signals, profile)
    {points, signals} = add_resolution_signal(points, signals, profile)

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

  defp add_datacenter_signal(points, signals, profile) do
    if datacenter_asn?(profile[:asn]) do
      {points + 35, [:datacenter_asn | signals]}
    else
      {points, signals}
    end
  end

  # Only fires if we ALSO match the datacenter ASN signal — a mobile UA on a
  # residential ISP is normal; a mobile UA on an OVH IP is almost certainly
  # spoofed.
  defp add_spoofed_ua_signal(points, signals, profile) do
    if datacenter_asn?(profile[:asn]) and mobile_ua?(profile[:user_agent]) do
      {points + 20, [:spoofed_mobile_ua | signals]}
    else
      {points, signals}
    end
  end

  defp add_ip_rotation_signal(points, signals, profile) do
    case profile[:visitor_ip_count] do
      n when is_integer(n) and n >= 3 -> {points + 20, [:ip_rotation | signals]}
      _ -> {points, signals}
    end
  end

  # Two-tier bucket — very_high_pageviews (200+) replaces high_pageviews
  # (50–199) rather than stacking.
  defp add_pageview_signal(points, signals, profile) do
    case profile[:session_pageviews] do
      n when is_integer(n) and n >= 200 -> {points + 20, [:very_high_pageviews | signals]}
      n when is_integer(n) and n >= 50 -> {points + 10, [:high_pageviews | signals]}
      _ -> {points, signals}
    end
  end

  defp add_systematic_crawl_signal(points, signals, profile) do
    paths = List.wrap(profile[:page_paths])
    prefixes = List.wrap(profile[:content_path_prefixes])

    if paths != [] and prefixes != [] do
      matching = Enum.count(paths, &path_matches_any?(&1, prefixes))
      ratio = matching / length(paths)

      if ratio > 0.8 do
        {points + 15, [:systematic_crawl | signals]}
      else
        {points, signals}
      end
    else
      {points, signals}
    end
  end

  defp add_referrer_signal(points, signals, profile) do
    case profile[:referrer] do
      nil -> {points + 5, [:no_referrer | signals]}
      "" -> {points + 5, [:no_referrer | signals]}
      _ -> {points, signals}
    end
  end

  defp add_robotic_timing_signal(points, signals, profile) do
    intervals = profile[:request_intervals_ms]

    case intervals do
      list when is_list(list) and length(list) >= 5 ->
        sd = std_dev(list)

        if sd < 300.0 do
          {points + 10, [:robotic_timing | signals]}
        else
          {points, signals}
        end

      _ ->
        {points, signals}
    end
  end

  defp add_resolution_signal(points, signals, profile) do
    if (profile[:screen_resolution] || "") in @suspicious_resolutions do
      {points + 5, [:suspicious_resolution | signals]}
    else
      {points, signals}
    end
  end

  # ---------------- Predicates ----------------

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
    String.contains?(ua_lower, "iphone") or String.contains?(ua_lower, "android")
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
end
