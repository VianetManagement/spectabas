defmodule Spectabas.Events.IntentClassifier do
  @moduledoc """
  Classifies visitor intent based on session behavior signals.

  Intent categories:
  - buying     — visited pricing/checkout/signup, came from paid ad
  - researching — 3+ pages, long duration, deep content
  - comparing  — came from comparison/review site, revisited pricing
  - support    — visited help/contact/docs/faq pages
  - returning  — has prior sessions (cookie-based returning visitor)
  - browsing   — 1-2 pages, moderate time, no conversion signals
  - bot        — datacenter IP, headless UA, no interaction
  """

  @buying_paths ~w(/pricing /checkout /signup /register /subscribe /buy /order /cart /payment /plan /plans /upgrade)
  @support_paths ~w(/help /contact /support /docs /documentation /faq /knowledgebase /kb /status /ticket)
  @comparison_referrers ~w(g2.com capterra.com trustradius.com getapp.com alternativeto.net
                           producthunt.com trustpilot.com gartner.com softwareadvice.com)

  @doc """
  Classify a visitor's intent based on event data and session context.

  Accepts the enriched event map and session metadata.
  Returns an intent string.
  """
  def classify(event, session_context \\ %{}) do
    signals = collect_signals(event, session_context)
    determine_intent(signals)
  end

  defp collect_signals(event, session_context) do
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
      is_buying_page: is_buying_page?(url_path),
      is_support_page: is_support_page?(url_path),
      is_comparison_referrer: is_comparison_referrer?(referrer),
      is_paid: is_paid_traffic?(utm_medium, utm_source),
      session_pageviews: session_pageviews,
      is_returning: is_returning
    }
  end

  defp determine_intent(signals) do
    cond do
      # Bot detection takes priority
      signals.is_bot || (signals.is_datacenter && signals.session_pageviews <= 1) ->
        "bot"

      # Buying intent: visited conversion pages or came from paid with buying page
      signals.is_buying_page && signals.is_paid ->
        "buying"

      signals.is_buying_page ->
        "buying"

      # Comparing: came from a comparison/review site
      signals.is_comparison_referrer ->
        "comparing"

      # Support: visiting help/docs/contact pages
      signals.is_support_page ->
        "support"

      # Returning visitor with direct access
      signals.is_returning && signals.referrer == "" ->
        "returning"

      # Researching: multiple pages in a session
      signals.session_pageviews >= 3 ->
        "researching"

      # Paid traffic not on buying pages = researching via ads
      signals.is_paid ->
        "researching"

      # Default: browsing
      true ->
        "browsing"
    end
  end

  defp is_buying_page?(path) do
    Enum.any?(@buying_paths, &String.contains?(path, &1))
  end

  defp is_support_page?(path) do
    Enum.any?(@support_paths, &String.contains?(path, &1))
  end

  defp is_comparison_referrer?(referrer) do
    referrer = String.downcase(referrer)
    Enum.any?(@comparison_referrers, &String.contains?(referrer, &1))
  end

  defp is_paid_traffic?(medium, source) do
    medium in ~w(cpc ppc paid paid-search paidsearch display retargeting) ||
      String.contains?(source, "adwords") ||
      String.contains?(source, "ads")
  end
end
