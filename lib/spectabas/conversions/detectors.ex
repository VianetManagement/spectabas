defmodule Spectabas.Conversions.Detectors do
  @moduledoc """
  Detection logic for conversion events. Three sources:

    * `stripe_payment` — scans `ecommerce_events` (CH) for new orders since
      the last detector run, matches each to its visitor and click_id, and
      writes a conversion row with the actual amount paid.

    * `url_pattern` — scans recent pageviews against site-configured URL
      patterns (regex / glob). One conversion per visitor per action.

    * `click_element` — scans `_click` custom events against a configured
      element selector (`#id` or `text:button text`).

  All three are idempotent via `Conversion.dedup_key`. Run from
  `Workers.ConversionDetector`.
  """

  alias Spectabas.{ClickHouse, Conversions, Repo}
  alias Spectabas.Conversions.{Conversion, ConversionAction}
  alias Spectabas.Sites.Site
  import Ecto.Query
  require Logger

  @scan_window_minutes 90

  @doc "Run all detectors for one site. Returns the count of new conversions."
  def run_for_site(%Site{} = site) do
    actions = Conversions.list_active_actions(site)

    if actions == [] do
      0
    else
      since = scan_since(site.id)

      counts = [
        run_stripe_detector(site, actions, since),
        run_url_pattern_detector(site, actions, since),
        run_click_element_detector(site, actions, since)
      ]

      Enum.sum(counts)
    end
  end

  # Each detector picks "scan from" using max(occurred_at) of conversions for
  # this site, plus a small buffer so a clock-skewed event doesn't get missed.
  defp scan_since(site_id) do
    last =
      Repo.one(
        from(c in Conversion,
          where: c.site_id == ^site_id,
          select: max(c.inserted_at)
        )
      )

    cond do
      is_nil(last) -> DateTime.add(DateTime.utc_now(), -90 * 86_400, :second)
      true -> DateTime.add(last, -@scan_window_minutes * 60, :second)
    end
  end

  # ---- Stripe detector ----

  defp run_stripe_detector(site, actions, since) do
    case Enum.filter(actions, &(&1.detection_type == "stripe_payment")) do
      [] -> 0
      [action | _] -> scan_stripe_payments(site, action, since)
    end
  end

  defp scan_stripe_payments(%Site{} = site, %ConversionAction{} = action, since) do
    sql = """
    SELECT
      order_id,
      visitor_id,
      revenue,
      currency,
      timestamp
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND import_source = 'stripe'
      AND timestamp >= #{ClickHouse.param(format_dt(since))}
      AND timestamp <= #{ClickHouse.param(format_dt(DateTime.utc_now()))}
    ORDER BY timestamp ASC
    LIMIT 5000
    SETTINGS max_execution_time = 30
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.reduce(rows, 0, fn row, acc ->
          case record_stripe(site, action, row) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end

  defp record_stripe(site, action, row) do
    order_id = row["order_id"] || ""
    visitor_id = row["visitor_id"] || ""
    revenue = row["revenue"] || 0
    currency = row["currency"] || "USD"

    occurred_at =
      case parse_dt(row["timestamp"]) do
        %DateTime{} = dt -> dt
        _ -> DateTime.utc_now()
      end

    email = lookup_email_for_visitor(site.id, visitor_id)

    Conversions.record(site, action, %{
      visitor_id: visitor_id,
      email: email,
      occurred_at: occurred_at,
      value: revenue,
      currency: currency,
      detection_source: "stripe",
      source_reference: order_id,
      dedup_key: "stripe:#{order_id}",
      scraper_score: nil
    })
  end

  defp lookup_email_for_visitor(_site_id, ""), do: nil
  defp lookup_email_for_visitor(_site_id, nil), do: nil

  defp lookup_email_for_visitor(site_id, visitor_id) do
    Repo.one(
      from(v in Spectabas.Visitors.Visitor,
        where: v.site_id == ^site_id and v.id == ^visitor_id,
        select: v.email
      )
    )
  end

  # ---- URL-pattern detector ----

  defp run_url_pattern_detector(site, actions, since) do
    pattern_actions = Enum.filter(actions, &(&1.detection_type == "url_pattern"))

    Enum.reduce(pattern_actions, 0, fn action, acc ->
      acc + scan_url_pattern(site, action, since)
    end)
  end

  defp scan_url_pattern(%Site{} = site, %ConversionAction{} = action, since) do
    pattern = Map.get(action.detection_config || %{}, "url_pattern", "")

    if pattern == "" do
      0
    else
      ch_pattern = glob_to_clickhouse_like(pattern)

      sql = """
      SELECT visitor_id, url_path, min(timestamp) AS first_seen
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'pageview'
        AND ip_is_bot = 0
        AND timestamp >= #{ClickHouse.param(format_dt(since))}
        AND url_path LIKE #{ClickHouse.param(ch_pattern)}
      GROUP BY visitor_id, url_path
      ORDER BY first_seen ASC
      LIMIT 5000
      SETTINGS max_execution_time = 30
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          Enum.reduce(rows, 0, fn row, acc ->
            case record_event_match(site, action, row, "pageview") do
              {:ok, _} -> acc + 1
              _ -> acc
            end
          end)

        _ ->
          0
      end
    end
  end

  # Convert simple shell-style glob to ClickHouse LIKE pattern.
  # `/welcome*` → `/welcome%`,  `/account/*` → `/account/%`.
  defp glob_to_clickhouse_like(pattern) do
    pattern
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
    |> String.replace("*", "%")
  end

  # ---- Click-element detector ----

  defp run_click_element_detector(site, actions, since) do
    click_actions = Enum.filter(actions, &(&1.detection_type == "click_element"))

    Enum.reduce(click_actions, 0, fn action, acc ->
      acc + scan_click_element(site, action, since)
    end)
  end

  defp scan_click_element(%Site{} = site, %ConversionAction{} = action, since) do
    selector = Map.get(action.detection_config || %{}, "selector", "")

    cond do
      selector == "" ->
        0

      String.starts_with?(selector, "#") ->
        scan_click_by_id(site, action, since, String.trim_leading(selector, "#"))

      String.starts_with?(selector, "text:") ->
        scan_click_by_text(site, action, since, String.trim_leading(selector, "text:"))

      true ->
        0
    end
  end

  defp scan_click_by_id(site, action, since, id) do
    sql = """
    SELECT visitor_id, min(timestamp) AS first_seen
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND event_type = 'custom'
      AND event_name = '_click'
      AND ip_is_bot = 0
      AND timestamp >= #{ClickHouse.param(format_dt(since))}
      AND JSONExtractString(properties, '_id') = #{ClickHouse.param(id)}
    GROUP BY visitor_id
    LIMIT 5000
    SETTINGS max_execution_time = 30
    """

    run_click_query(site, action, sql)
  end

  defp scan_click_by_text(site, action, since, text) do
    sql = """
    SELECT visitor_id, min(timestamp) AS first_seen
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND event_type = 'custom'
      AND event_name = '_click'
      AND ip_is_bot = 0
      AND timestamp >= #{ClickHouse.param(format_dt(since))}
      AND JSONExtractString(properties, '_text') = #{ClickHouse.param(text)}
    GROUP BY visitor_id
    LIMIT 5000
    SETTINGS max_execution_time = 30
    """

    run_click_query(site, action, sql)
  end

  defp run_click_query(site, action, sql) do
    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.reduce(rows, 0, fn row, acc ->
          case record_event_match(site, action, row, "click_element") do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end

  defp record_event_match(site, action, row, source) do
    visitor_id = row["visitor_id"] || ""

    if visitor_id == "" do
      :skip
    else
      occurred_at =
        case parse_dt(row["first_seen"]) do
          %DateTime{} = dt -> dt
          _ -> DateTime.utc_now()
        end

      # One conversion per (visitor_id, action) — listing-creation only fires
      # the first time, signup ditto. The dedup_key handles this.
      dedup_key = "#{source}:#{visitor_id}"

      email = lookup_email_for_visitor(site.id, visitor_id)

      Conversions.record(site, action, %{
        visitor_id: visitor_id,
        email: email,
        occurred_at: occurred_at,
        detection_source: source,
        source_reference: row["url_path"] || row["selector"] || "",
        dedup_key: dedup_key,
        scraper_score: nil
      })
    end
  end

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp parse_dt(s) when is_binary(s) do
    # ClickHouse returns timestamps as "YYYY-MM-DD HH:MM:SS" UTC.
    case DateTime.from_iso8601(String.replace(s, " ", "T") <> "Z") do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil
end
