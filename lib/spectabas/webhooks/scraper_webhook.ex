defmodule Spectabas.Webhooks.ScraperWebhook do
  require Logger

  alias Spectabas.Repo
  alias Spectabas.Sites.Site
  alias Spectabas.Visitors.Visitor
  alias Spectabas.Webhooks.WebhookDelivery

  def send_flag(%Site{} = site, %Visitor{} = visitor, score_result, total_pageviews) do
    url = String.trim_trailing(site.scraper_webhook_url, "/")
    secret = site.scraper_webhook_secret
    signals = Enum.map(score_result.signals, &to_string/1)

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
        signals: signals,
        total_pageviews: total_pageviews
      }
    }

    result =
      case do_post(url, payload, secret) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.notice(
            "[ScraperWebhook] Sent flag for visitor #{visitor.id} site=#{site.id} score=#{score_result.score} status=#{status}"
          )

          {:ok, %{request: payload, status: status, url: url}}

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "[ScraperWebhook] Non-OK response for visitor #{visitor.id}: status=#{status} body=#{inspect(body)}"
          )

          {:error, %{request: payload, status: status, url: url}}

        {:error, reason} ->
          Logger.warning("[ScraperWebhook] Failed for visitor #{visitor.id}: #{inspect(reason)}")

          {:error, %{request: payload, status: nil, url: url, reason: reason}}
      end

    log_delivery(site.id, visitor.id, "flag", score_result.score, signals, url, result)
    result
  end

  def send_deactivate(%Site{} = site, %Visitor{} = visitor) do
    url = String.trim_trailing(site.scraper_webhook_url, "/") <> "/deactivate"
    secret = site.scraper_webhook_secret

    payload = %{
      identifiers: %{
        ip_addresses: visitor.known_ips || [],
        fingerprint: visitor.external_id || "",
        user_id: parse_user_id(visitor.user_id)
      }
    }

    result =
      case do_post(url, payload, secret) do
        {:ok, %{status: status}} when status in 200..299 ->
          Logger.notice(
            "[ScraperWebhook] Sent deactivate for visitor #{visitor.id} site=#{site.id}"
          )

          {:ok, %{request: payload, status: status, url: url}}

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "[ScraperWebhook] Deactivate non-OK for visitor #{visitor.id}: status=#{status} body=#{inspect(body)}"
          )

          {:error, %{request: payload, status: status, url: url}}

        {:error, reason} ->
          Logger.warning(
            "[ScraperWebhook] Deactivate failed for visitor #{visitor.id}: #{inspect(reason)}"
          )

          {:error, %{request: payload, status: nil, url: url, reason: reason}}
      end

    log_delivery(site.id, visitor.id, "deactivate", nil, [], url, result)
    result
  end

  def list_deliveries(site_id, opts \\ []) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 50)

    from(d in WebhookDelivery,
      where: d.site_id == ^site_id,
      order_by: [desc: d.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def cleanup_old_deliveries(days \\ 30) do
    import Ecto.Query

    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)

    {count, _} =
      from(d in WebhookDelivery, where: d.inserted_at < ^cutoff)
      |> Repo.delete_all()

    count
  end

  defp log_delivery(site_id, visitor_id, event_type, score, signals, url, result) do
    {success, http_status, error_message} =
      case result do
        {:ok, %{status: s}} -> {true, s, nil}
        {:error, %{status: s, reason: r}} -> {false, s, inspect(r)}
        {:error, %{status: s}} -> {false, s, "HTTP #{s}"}
      end

    %WebhookDelivery{}
    |> WebhookDelivery.changeset(%{
      site_id: site_id,
      visitor_id: visitor_id,
      event_type: event_type,
      score: score,
      signals: signals,
      http_status: http_status,
      success: success,
      error_message: error_message,
      url: url
    })
    |> Repo.insert()
  rescue
    e -> Logger.warning("[ScraperWebhook] Failed to log delivery: #{inspect(e)}")
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
