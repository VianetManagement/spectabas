defmodule Spectabas.Events.IntentClassifier do
  @moduledoc """
  Classifies visitor intent based on session behavior signals and site-specific configuration.

  Intent categories:
  - buying     — visited conversion/purchase pages (site-configurable)
  - engaging   — using core app features like search, messaging, listings (site-configurable)
  - researching — 2+ pages, or paid traffic viewing content
  - comparing  — came from comparison/review site
  - support    — visited help/contact/docs/faq pages (site-configurable)
  - returning  — returning visitor (has prior sessions)
  - browsing   — low engagement, no conversion signals
  - bot        — datacenter IP, headless UA, no interaction
  """

  # Default paths used when site has no custom config
  @default_buying_paths ~w(/pricing /checkout /signup /register /subscribe /buy /order /cart /payment /plan /plans /upgrade)
  @default_support_paths ~w(/help /contact /support /docs /documentation /faq /knowledgebase /kb /status /ticket)
  @default_engaging_paths ~w(/search /listings /messages /notifications /dashboard /account /profile /settings)
  @default_comparison_referrers ~w(g2.com capterra.com trustradius.com getapp.com alternativeto.net
                                    producthunt.com trustpilot.com gartner.com softwareadvice.com)
  @default_researching_threshold 2

  @doc """
  Classify a visitor's intent based on event data, session context, and optional site config.

  `site_config` is a map with optional keys:
  - "buying_paths" — list of path fragments that indicate buying intent
  - "engaging_paths" — list of path fragments that indicate active app usage
  - "support_paths" — list of path fragments that indicate support intent
  - "comparison_referrers" — list of referrer domains for comparison intent
  - "researching_threshold" — min pageviews to classify as researching (default 2)
  """
  def classify(event, session_context \\ %{}, site_config \\ %{}) do
    config = normalize_config(site_config)
    signals = collect_signals(event, session_context, config)
    determine_intent(signals, config)
  end

  defp normalize_config(nil), do: normalize_config(%{})

  defp normalize_config(config) do
    %{
      buying_paths: get_paths(config, "buying_paths", @default_buying_paths),
      engaging_paths: get_paths(config, "engaging_paths", @default_engaging_paths),
      support_paths: get_paths(config, "support_paths", @default_support_paths),
      comparison_referrers:
        get_paths(config, "comparison_referrers", @default_comparison_referrers),
      researching_threshold:
        get_int(config, "researching_threshold", @default_researching_threshold)
    }
  end

  defp get_paths(config, key, default) do
    case Map.get(config, key) do
      list when is_list(list) and list != [] -> list
      _ -> default
    end
  end

  defp get_int(config, key, default) do
    case Map.get(config, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp collect_signals(event, session_context, config) do
    url_path = to_string(event[:url_path] || event["url_path"] || "/") |> String.downcase()
    referrer = to_string(event[:referrer_domain] || event["referrer_domain"] || "")
    utm_medium = to_string(event[:utm_medium] || event["utm_medium"] || "") |> String.downcase()
    utm_source = to_string(event[:utm_source] || event["utm_source"] || "") |> String.downcase()

    is_bot = (event[:ip_is_bot] || event["ip_is_bot"] || 0) == 1
    is_datacenter = (event[:ip_is_datacenter] || event["ip_is_datacenter"] || 0) == 1

    session_pageviews = session_context[:pageview_count] || 0
    is_returning = session_context[:is_returning] || false

    %{
      url_path: url_path,
      referrer: referrer,
      utm_medium: utm_medium,
      utm_source: utm_source,
      is_bot: is_bot,
      is_datacenter: is_datacenter,
      is_buying_page: path_matches?(url_path, config.buying_paths),
      is_engaging_page: path_matches?(url_path, config.engaging_paths),
      is_support_page: path_matches?(url_path, config.support_paths),
      is_comparison_referrer: referrer_matches?(referrer, config.comparison_referrers),
      is_paid: is_paid_traffic?(utm_medium, utm_source),
      session_pageviews: session_pageviews,
      is_returning: is_returning
    }
  end

  defp determine_intent(signals, config) do
    cond do
      # Bot detection takes priority
      signals.is_bot || (signals.is_datacenter && signals.session_pageviews <= 1) ->
        "bot"

      # Buying intent: visited conversion pages
      signals.is_buying_page ->
        "buying"

      # Comparing: came from a comparison/review site
      signals.is_comparison_referrer ->
        "comparing"

      # Support: visiting help/docs/contact pages
      signals.is_support_page ->
        "support"

      # Engaging: actively using core app features (search, listings, messaging, etc.)
      signals.is_engaging_page ->
        "engaging"

      # Returning visitor (any referrer, not just direct)
      signals.is_returning ->
        "returning"

      # Researching: multiple pages or paid traffic viewing content
      signals.session_pageviews >= config.researching_threshold ->
        "researching"

      signals.is_paid ->
        "researching"

      # Default: browsing
      true ->
        "browsing"
    end
  end

  defp path_matches?(path, patterns) do
    Enum.any?(patterns, &String.contains?(path, &1))
  end

  defp referrer_matches?(referrer, patterns) do
    referrer = String.downcase(referrer)
    Enum.any?(patterns, &String.contains?(referrer, &1))
  end

  defp is_paid_traffic?(medium, source) do
    medium in ~w(cpc ppc paid paid-search paidsearch display retargeting) ||
      String.contains?(source, "adwords") ||
      String.contains?(source, "ads")
  end
end
