defmodule Spectabas.Events.EventSchema do
  @moduledoc """
  Maps an enriched event map to a ClickHouse-ready row.
  All fields are present with correct types; UUIDs as strings,
  timestamps as ISO 8601.
  """

  @doc """
  Convert an enriched event map (atom keys) to a map suitable for
  `ClickHouse.insert("events", [row])`.
  """
  def to_row(event) when is_map(event) do
    %{
      # identifiers
      "event_id" => to_string(event[:event_id] || Ecto.UUID.generate()),
      "site_id" => to_integer(event[:site_id]),
      "visitor_id" => to_string(event[:visitor_id] || ""),
      "session_id" => to_string(event[:session_id] || ""),

      # event metadata
      "event_type" => to_string(event[:event_type] || "pageview"),
      "event_name" => to_string(event[:event_name] || ""),
      "timestamp" => format_timestamp(event[:timestamp]),

      # page / referrer (must match ClickHouse table columns exactly)
      "url_path" => truncate(to_string(event[:url_path] || ""), 2048),
      "url_host" => truncate(to_string(event[:url_host] || ""), 512),
      "referrer_domain" => truncate(to_string(event[:referrer_domain] || ""), 512),
      "referrer_url" => truncate(to_string(event[:referrer] || event[:referrer_url] || ""), 2048),

      # UTM parameters
      "utm_source" => truncate(to_string(event[:utm_source] || ""), 256),
      "utm_medium" => truncate(to_string(event[:utm_medium] || ""), 256),
      "utm_campaign" => truncate(to_string(event[:utm_campaign] || ""), 256),
      "utm_term" => truncate(to_string(event[:utm_term] || ""), 256),
      "utm_content" => truncate(to_string(event[:utm_content] || ""), 256),

      # device / UA
      "device_type" => to_string(event[:device_type] || ""),
      "browser" => to_string(event[:browser] || ""),
      "browser_version" => to_string(event[:browser_version] || ""),
      "os" => to_string(event[:os] || ""),
      "os_version" => to_string(event[:os_version] || ""),
      "screen_width" => to_integer(event[:screen_width]),
      "screen_height" => to_integer(event[:screen_height]),

      # duration
      "duration_s" => to_integer(event[:duration]),

      # IP enrichment
      "ip_address" => to_string(event[:ip_address] || ""),
      "ip_country" => to_string(event[:ip_country] || ""),
      "ip_country_name" => to_string(event[:ip_country_name] || ""),
      "ip_continent" => to_string(event[:ip_continent] || ""),
      "ip_continent_name" => to_string(event[:ip_continent_name] || ""),
      "ip_region_code" => to_string(event[:ip_region_code] || ""),
      "ip_region_name" => to_string(event[:ip_region_name] || ""),
      "ip_city" => to_string(event[:ip_city] || ""),
      "ip_postal_code" => to_string(event[:ip_postal_code] || ""),
      "ip_lat" => to_float(event[:ip_lat]),
      "ip_lon" => to_float(event[:ip_lon]),
      "ip_accuracy_radius" => to_integer(event[:ip_accuracy_radius]),
      "ip_timezone" => to_string(event[:ip_timezone] || ""),
      "ip_asn" => to_integer(event[:ip_asn]),
      "ip_asn_org" => to_string(event[:ip_asn_org] || ""),
      "ip_org" => to_string(event[:ip_org] || ""),
      "ip_is_datacenter" => to_uint8(event[:ip_is_datacenter]),
      "ip_is_vpn" => to_uint8(event[:ip_is_vpn]),
      "ip_is_tor" => to_uint8(event[:ip_is_tor]),
      "ip_is_bot" => to_uint8(event[:ip_is_bot]),
      "ip_is_eu" => to_uint8(event[:ip_is_eu]),
      "ip_gdpr_anonymized" => to_uint8(event[:ip_gdpr_anonymized]),
      "visitor_intent" => to_string(event[:visitor_intent] || ""),
      "user_agent" => truncate(to_string(event[:user_agent] || ""), 512),
      "browser_fingerprint" => to_string(event[:browser_fingerprint] || ""),

      # custom properties (JSON string)
      "properties" => Jason.encode!(event[:props] || event[:properties] || %{})
    }
  end

  defp format_timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_timestamp(s) when is_binary(s), do: s

  defp to_integer(nil), do: 0
  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_float(v), do: round(v)
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)

  defp to_float(nil), do: 0.0
  defp to_float(v) when is_float(v), do: v
  defp to_float(v) when is_integer(v), do: v / 1
  defp to_float(v) when is_binary(v), do: String.to_float(v)

  defp to_uint8(nil), do: 0
  defp to_uint8(true), do: 1
  defp to_uint8(false), do: 0
  defp to_uint8(1), do: 1
  defp to_uint8(_), do: 0

  defp truncate(s, max) when byte_size(s) > max, do: String.slice(s, 0, max)
  defp truncate(s, _max), do: s
end
