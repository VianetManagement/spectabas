defmodule Spectabas.Analytics.ChannelClassifier do
  @moduledoc "Classifies traffic sources into marketing channels."

  @search_engines ~w(google.com google.co bing.com duckduckgo.com yahoo.com baidu.com yandex.ru yandex.com ecosia.org brave.com search.brave.com)
  @social_networks ~w(facebook.com fb.com instagram.com twitter.com x.com linkedin.com reddit.com tiktok.com youtube.com pinterest.com threads.net mastodon.social)
  @ai_assistants ~w(chatgpt.com chat.openai.com claude.ai perplexity.ai gemini.google.com copilot.microsoft.com poe.com you.com phind.com)
  @email_patterns ~w(mail.google.com outlook.live.com mail.yahoo.com webmail)

  def classify(referrer_domain, utm_source \\ "", utm_medium \\ "") do
    medium = if utm_medium != "", do: String.downcase(utm_medium), else: ""

    cond do
      medium != "" and
          String.contains?(medium, ["paid_social", "paidsocial"]) ->
        "Paid Social"

      medium != "" and
          String.contains?(medium, ["cpc", "ppc", "paidsearch"]) ->
        "Paid Search"

      medium == "paid" ->
        "Paid Search"

      medium == "email" ->
        "Email"

      medium == "social" ->
        "Social Networks"

      referrer_domain == "" and utm_source == "" ->
        "Direct"

      matches_any?(referrer_domain, @ai_assistants) ->
        "AI Assistants"

      matches_any?(referrer_domain, @email_patterns) ->
        "Email"

      matches_any?(referrer_domain, @search_engines) ->
        "Search Engines"

      matches_any?(referrer_domain, @social_networks) ->
        "Social Networks"

      referrer_domain != "" ->
        "Websites"

      utm_source != "" ->
        "Other Campaigns"

      true ->
        "Direct"
    end
  end

  defp matches_any?("", _patterns), do: false

  defp matches_any?(domain, patterns) do
    domain = String.downcase(domain)
    Enum.any?(patterns, fn p -> String.contains?(domain, p) end)
  end

  def channel_color(channel) do
    case channel do
      "Search Engines" -> "bg-blue-100 text-blue-800"
      "Social Networks" -> "bg-pink-100 text-pink-800"
      "AI Assistants" -> "bg-purple-100 text-purple-800"
      "Direct" -> "bg-gray-100 text-gray-800"
      "Email" -> "bg-amber-100 text-amber-800"
      "Paid Search" -> "bg-green-100 text-green-800"
      "Paid Social" -> "bg-rose-100 text-rose-800"
      "Websites" -> "bg-indigo-100 text-indigo-800"
      "Other Campaigns" -> "bg-teal-100 text-teal-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end
end
