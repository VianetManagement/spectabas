defmodule Spectabas.Analytics.JourneyMapper do
  @moduledoc """
  Computes visitor journeys grouped by page TYPE (not individual URL).

  URLs are mapped to a short label using the site's `scraper_content_prefixes`
  as the grouping rules: `/listings/golden-retriever-123` → "Listings",
  `/premier/chihuahua-789` → "Premier", etc. Paths that don't match any
  prefix keep their literal value (truncated to the first two segments).

  Journeys are split into three outcome-based buckets:
  - **Converter journeys** — sessions touching a conversion page
  - **Engaged journeys** — 3+ pages, no conversion
  - **Bounce paths** — 1-page sessions
  """

  alias Spectabas.{ClickHouse, Accounts}
  alias Spectabas.Sites.Site
  alias Spectabas.Accounts.User
  import Spectabas.TypeHelpers, only: [to_num: 1]

  @doc """
  Returns `{:ok, %{converters: [...], engaged: [...], bounced: [...], stats: %{...}}}`.

  Each journey in converters/engaged is:
    %{path: "Homepage → Listings → Contact", visitors: 234, avg_duration: 180,
      sources: %{"google.com" => 120, "direct" => 80, ...}}

  Each bounce path is:
    %{page: "Listings", visitors: 4200, top_source: "google.com"}
  """
  def analyze(%Site{} = site, %User{} = user, date_range, _opts \\ []) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      site_p = ClickHouse.param(site.id)
      from_p = ClickHouse.param(fmt(date_range.from))
      to_p = ClickHouse.param(fmt(date_range.to))

      prefixes = List.wrap(site.scraper_content_prefixes)
      conv_pages = List.wrap(site.journey_conversion_pages)

      # Build the ClickHouse CASE expression that groups URLs into page types.
      # Runs server-side in CH so we group BEFORE aggregating — much cheaper.
      type_expr = build_page_type_sql(prefixes)

      # One row per session: ordered page-type sequence, duration, source,
      # and whether any page matched a conversion page.
      conv_check =
        if conv_pages != [] do
          checks =
            conv_pages
            |> Enum.map(fn p -> "url_path LIKE #{ClickHouse.param(p <> "%")}" end)
            |> Enum.join(" OR ")

          "maxIf(1, #{checks})"
        else
          "0"
        end

      session_sql = """
      SELECT
        session_id,
        groupArray(page_type) AS page_types,
        any(referrer_domain) AS source,
        maxIf(duration_s, event_type = 'duration' AND duration_s > 0) AS duration,
        #{conv_check} AS has_conversion
      FROM (
        SELECT
          session_id,
          event_type,
          url_path,
          referrer_domain,
          duration_s,
          timestamp,
          #{type_expr} AS page_type
        FROM events
        WHERE site_id = #{site_p}
          AND timestamp >= #{from_p}
          AND timestamp <= #{to_p}
          AND ip_is_bot = 0
        ORDER BY session_id, timestamp
      )
      GROUP BY session_id
      """

      case ClickHouse.query(session_sql, receive_timeout: 60_000) do
        {:ok, rows} ->
          sessions = Enum.map(rows, &parse_session/1)
          {:ok, classify_sessions(sessions)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ------------------------------------------------------------------ #
  # Page-type SQL builder                                               #
  # ------------------------------------------------------------------ #

  # Builds a ClickHouse CASE WHEN expression that maps url_path to a
  # human-readable page type label. Uses scraper_content_prefixes as the
  # grouping rules. Falls back to the first path segment.
  defp build_page_type_sql([]) do
    # No prefixes configured — use first path segment as the label.
    "if(url_path = '/', 'Homepage', splitByChar('/', url_path)[2])"
  end

  defp build_page_type_sql(prefixes) do
    whens =
      prefixes
      |> Enum.map(fn prefix ->
        label = prefix |> String.trim_leading("/") |> String.capitalize()
        "WHEN startsWith(url_path, #{ClickHouse.param(prefix)}) THEN #{ClickHouse.param(label)}"
      end)
      |> Enum.join("\n        ")

    """
    CASE
        WHEN url_path = '/' THEN 'Homepage'
        #{whens}
        ELSE if(url_path = '', '', splitByChar('/', url_path)[2])
      END
    """
  end

  # ------------------------------------------------------------------ #
  # Session parsing + classification                                    #
  # ------------------------------------------------------------------ #

  defp parse_session(row) do
    page_types = List.wrap(row["page_types"])

    # Collapse consecutive identical types: [Listings, Listings, Listings, Contact] → [Listings, Contact]
    collapsed = collapse_consecutive(page_types)

    %{
      pages: collapsed,
      page_count: length(page_types),
      source: normalize_source(row["source"]),
      duration: to_num(row["duration"]),
      converted: to_num(row["has_conversion"]) == 1
    }
  end

  defp collapse_consecutive([]), do: []

  defp collapse_consecutive(list) do
    list
    |> Enum.chunk_by(& &1)
    |> Enum.map(&hd/1)
  end

  defp normalize_source(nil), do: "Direct"
  defp normalize_source(""), do: "Direct"
  defp normalize_source(s), do: s

  defp classify_sessions(sessions) do
    {converters_raw, rest} = Enum.split_with(sessions, & &1.converted)
    {engaged_raw, bounce_raw} = Enum.split_with(rest, &(&1.page_count >= 3))

    converters = aggregate_journeys(converters_raw, 15)
    engaged = aggregate_journeys(engaged_raw, 15)
    bounced = aggregate_bounces(bounce_raw, 15)

    total = length(sessions)
    multi = Enum.count(sessions, &(&1.page_count >= 2))

    avg_pages =
      if total > 0,
        do: Float.round(Enum.reduce(sessions, 0, &(&1.page_count + &2)) / total, 1),
        else: 0.0

    stats = %{
      total_sessions: total,
      multi_page_sessions: multi,
      avg_pages_per_session: avg_pages,
      converting_sessions: length(converters_raw),
      engaged_sessions: length(engaged_raw),
      bounce_sessions: length(bounce_raw)
    }

    %{converters: converters, engaged: engaged, bounced: bounced, stats: stats}
  end

  defp aggregate_journeys(sessions, limit) do
    sessions
    |> Enum.group_by(&Enum.join(&1.pages, " → "))
    |> Enum.map(fn {path, group} ->
      visitors = length(group)

      avg_dur =
        if visitors > 0, do: round(Enum.reduce(group, 0, &(&1.duration + &2)) / visitors), else: 0

      sources =
        group
        |> Enum.frequencies_by(& &1.source)
        |> Enum.sort_by(&(-elem(&1, 1)))
        |> Enum.take(3)

      %{
        path: path,
        pages: hd(group).pages,
        visitors: visitors,
        avg_duration: avg_dur,
        sources: sources
      }
    end)
    |> Enum.sort_by(&(-&1.visitors))
    |> Enum.take(limit)
  end

  defp aggregate_bounces(sessions, limit) do
    sessions
    |> Enum.group_by(fn s -> {List.first(s.pages) || "Unknown", s.source} end)
    |> Enum.map(fn {{page, source}, group} ->
      %{page: page, source: source, visitors: length(group)}
    end)
    |> Enum.sort_by(&(-&1.visitors))
    |> Enum.take(limit)
  end

  # ------------------------------------------------------------------ #
  # Helpers                                                             #
  # ------------------------------------------------------------------ #

  defp authorize(site, user) do
    if Accounts.can_access_site?(user, site), do: :ok, else: {:error, :unauthorized}
  end

  defp ensure_date_range(period) when is_atom(period) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from =
      case period do
        :day -> DateTime.add(now, -24, :hour)
        :week -> DateTime.add(now, -7, :day)
        :month -> DateTime.add(now, -30, :day)
        _ -> DateTime.add(now, -7, :day)
      end

    %{from: from, to: now}
  end

  defp ensure_date_range(%{from: _, to: _} = dr), do: dr

  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
