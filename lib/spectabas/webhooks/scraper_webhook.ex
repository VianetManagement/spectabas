defmodule Spectabas.Webhooks.ScraperWebhook do
  require Logger
  import Bitwise

  alias Spectabas.Repo
  alias Spectabas.Sites.Site
  alias Spectabas.Visitors.Visitor
  alias Spectabas.Webhooks.WebhookDelivery

  # Default prefix length for datacenter IPv6 CIDR ranges.
  # /64 covers a single subnet — the standard rotation pool for
  # scrapers cycling through addresses on a single server.
  @ipv6_prefix_length 64

  def send_flag(%Site{} = site, %Visitor{} = visitor, score_result, total_pageviews) do
    url = String.trim_trailing(site.scraper_webhook_url, "/")
    secret = site.scraper_webhook_secret
    signals = Enum.map(score_result.signals, &to_string/1)
    has_datacenter = :datacenter_asn in score_result.signals
    ips = visitor.known_ips || []

    ip_ranges =
      if has_datacenter do
        ips
        |> Enum.flat_map(&ipv6_to_cidr/1)
        |> Enum.uniq()
      else
        []
      end

    payload = %{
      identifiers: %{
        ip_addresses: ips,
        ip_ranges: ip_ranges,
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
    ips = visitor.known_ips || []

    ip_ranges =
      ips
      |> Enum.flat_map(&ipv6_to_cidr/1)
      |> Enum.uniq()

    payload = %{
      identifiers: %{
        ip_addresses: ips,
        ip_ranges: ip_ranges,
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

  def list_visitor_deliveries(visitor_id, opts \\ []) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 20)

    from(d in WebhookDelivery,
      where: d.visitor_id == ^visitor_id,
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

  # Converts an IPv6 address string to a CIDR prefix string (e.g. "2a04:4e41:3ec6:5198::/64").
  # IPv4 addresses are skipped — IPv4 rotation is rare and /32 is already exact.
  defp ipv6_to_cidr(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, {_, _, _, _, _, _, _, _} = addr} ->
        prefix = mask_ipv6(addr, @ipv6_prefix_length)
        [format_ipv6(prefix) <> "/#{@ipv6_prefix_length}"]

      _ ->
        # IPv4 or unparseable — skip
        []
    end
  end

  defp ipv6_to_cidr(_), do: []

  # Zero out bits beyond the prefix length in an IPv6 8-tuple of 16-bit words.
  defp mask_ipv6({a, b, c, d, e, f, g, h}, prefix_len) do
    full =
      a <<< 112 ||| b <<< 96 ||| c <<< 80 ||| d <<< 64 ||| e <<< 48 ||| f <<< 32 ||| g <<< 16 |||
        h

    shift = 128 - prefix_len
    masked = full >>> shift <<< shift

    {masked >>> 112 &&& 0xFFFF, masked >>> 96 &&& 0xFFFF, masked >>> 80 &&& 0xFFFF,
     masked >>> 64 &&& 0xFFFF, masked >>> 48 &&& 0xFFFF, masked >>> 32 &&& 0xFFFF,
     masked >>> 16 &&& 0xFFFF, masked &&& 0xFFFF}
  end

  defp format_ipv6({a, b, c, d, e, f, g, h}) do
    {a, b, c, d, e, f, g, h}
    |> :inet.ntoa()
    |> List.to_string()
  end
end
