defmodule Spectabas.Webhooks.ScraperWebhook do
  require Logger

  alias Spectabas.Sites.Site
  alias Spectabas.Visitors.Visitor

  @doc """
  Send a scraper detection webhook for a flagged visitor.

  Expects:
  - `site` with scraper_webhook_url and scraper_webhook_secret set
  - `visitor` from the visitors table (for known_ips, external_id, user_id)
  - `score_result` — %{score: integer, signals: [atom]}
  - `total_pageviews` — integer from ClickHouse
  """
  def send_flag(%Site{} = site, %Visitor{} = visitor, score_result, total_pageviews) do
    url = String.trim_trailing(site.scraper_webhook_url, "/")
    secret = site.scraper_webhook_secret

    payload = %{
      identifiers: %{
        ip_addresses: visitor.known_ips || [],
        fingerprint: visitor.external_id || "",
        user_id: parse_user_id(visitor.user_id)
      },
      score: score_result.score,
      activation_delay_hours: activation_delay(score_result.score),
      metadata: %{
        visitor_id: visitor.id,
        signals: Enum.map(score_result.signals, &to_string/1),
        total_pageviews: total_pageviews
      }
    }

    case do_post(url, payload, secret) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Logger.notice(
          "[ScraperWebhook] Sent flag for visitor #{visitor.id} site=#{site.id} score=#{score_result.score} status=#{status}"
        )

        {:ok, %{request: payload, response: body, status: status, url: url}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "[ScraperWebhook] Non-OK response for visitor #{visitor.id}: status=#{status} body=#{inspect(body)}"
        )

        {:error, %{request: payload, response: body, status: status, url: url}}

      {:error, reason} ->
        Logger.warning("[ScraperWebhook] Failed for visitor #{visitor.id}: #{inspect(reason)}")
        {:error, %{request: payload, response: nil, status: nil, url: url, reason: reason}}
    end
  end

  @doc """
  Send a deactivation webhook to remove a false-positive flag.
  """
  def send_deactivate(%Site{} = site, %Visitor{} = visitor) do
    url =
      String.trim_trailing(site.scraper_webhook_url, "/") <> "/deactivate"

    secret = site.scraper_webhook_secret

    payload = %{
      identifiers: %{
        ip_addresses: visitor.known_ips || [],
        fingerprint: visitor.external_id || "",
        user_id: parse_user_id(visitor.user_id)
      }
    }

    case do_post(url, payload, secret) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Logger.notice(
          "[ScraperWebhook] Sent deactivate for visitor #{visitor.id} site=#{site.id}"
        )

        {:ok, %{request: payload, response: body, status: status, url: url}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          "[ScraperWebhook] Deactivate non-OK for visitor #{visitor.id}: status=#{status} body=#{inspect(body)}"
        )

        {:error, %{request: payload, response: body, status: status, url: url}}

      {:error, reason} ->
        Logger.warning(
          "[ScraperWebhook] Deactivate failed for visitor #{visitor.id}: #{inspect(reason)}"
        )

        {:error, %{request: payload, response: nil, status: nil, url: url, reason: reason}}
    end
  end

  defp activation_delay(score) when score >= 95, do: 0
  defp activation_delay(_score), do: 48

  defp parse_user_id(nil), do: nil
  defp parse_user_id(""), do: nil

  defp parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp do_post(url, payload, secret) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{secret}"}
    ]

    Req.post(url, json: payload, headers: headers, receive_timeout: 10_000)
  end
end
