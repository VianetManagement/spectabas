defmodule Spectabas.Analytics.Segment do
  @moduledoc """
  Builds ClickHouse WHERE clauses from segment filter definitions.

  A segment is a list of filters, each with a field, operator, and value(s).
  Supported operators: is, is_not, contains, not_contains.

  Example:
      [
        %{"field" => "ip_country", "op" => "is", "value" => "US"},
        %{"field" => "browser", "op" => "is_not", "value" => "Chrome"},
        %{"field" => "url_path", "op" => "contains", "value" => "/blog"}
      ]
  """

  alias Spectabas.ClickHouse

  @allowed_fields ~w(
    ip_country ip_country_name ip_continent_name ip_region_name ip_city ip_timezone
    ip_asn ip_org
    ip_is_bot ip_is_datacenter ip_is_vpn
    browser os device_type
    referrer_domain utm_source utm_medium utm_campaign utm_term utm_content
    click_id_type
    url_path url_host
    event_type event_name
    visitor_intent
    returning identified scraper_whitelisted
  )

  # Fields that aren't direct columns on `events`. Filter translation has
  # to emit a `visitor_id IN (subquery)` (CH-only) or a pre-resolved
  # `visitor_id IN (uuid1, ...)` from a PG lookup. Callers pass `site_id`
  # via `to_sql/2` opts; PG-resolved fields are pre-fanned by `Cohorts`
  # before calling Analytics functions.
  @virtual_fields ~w(returning identified scraper_whitelisted)
  @pg_resolved_fields ~w(identified scraper_whitelisted)

  @doc """
  Convert a list of segment filters into a ClickHouse WHERE clause string.
  Returns an empty string if filters is nil or empty.

  Accepts an optional `:site_id` opt for virtual fields (currently
  `returning`) that need a site-scoped subquery. Filters on virtual
  fields are dropped silently when no `site_id` is provided.
  """
  def to_sql(filters, opts \\ [])

  def to_sql(nil, _opts), do: ""
  def to_sql([], _opts), do: ""

  def to_sql(filters, opts) when is_list(filters) do
    site_id = Keyword.get(opts, :site_id)

    clauses =
      filters
      |> Enum.filter(&valid_filter?/1)
      |> Enum.map(&filter_to_sql(&1, site_id))
      |> Enum.reject(&(&1 == ""))

    case clauses do
      [] -> ""
      _ -> Enum.join(clauses, "\n    ")
    end
  end

  @doc "Plain list of field names allowed in filters. Used by Cohort validation."
  def allowed_field_names, do: @allowed_fields

  @doc "List of fields available for segmentation."
  def available_fields do
    Enum.map(@allowed_fields, fn field ->
      %{
        field: field,
        label:
          field
          |> String.replace("_", " ")
          |> String.split()
          |> Enum.map(&String.capitalize/1)
          |> Enum.join(" ")
      }
    end)
  end

  @doc """
  Returns dropdown options for categorical filter fields.
  Queries ClickHouse for distinct values seen in the last 90 days.
  """
  def filter_options(site_id) do
    from =
      DateTime.utc_now() |> DateTime.add(-90 * 86400) |> Calendar.strftime("%Y-%m-%d %H:%M:%S")

    to = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
    site_p = ClickHouse.param(site_id)
    from_p = ClickHouse.param(from)
    to_p = ClickHouse.param(to)

    base_where =
      "site_id = #{site_p} AND timestamp >= #{from_p} AND timestamp <= #{to_p} AND ip_is_bot = 0 AND event_type = 'pageview'"

    queries = %{
      "countries" =>
        "SELECT DISTINCT ip_country AS v FROM events WHERE #{base_where} AND ip_country != '' ORDER BY v",
      "country_names" =>
        "SELECT DISTINCT ip_country_name AS v FROM events WHERE #{base_where} AND ip_country_name != '' ORDER BY v",
      "browsers" =>
        "SELECT DISTINCT browser AS v FROM events WHERE #{base_where} AND browser != '' ORDER BY v",
      "operating_systems" =>
        "SELECT DISTINCT os AS v FROM events WHERE #{base_where} AND os != '' ORDER BY v",
      "device_types" =>
        "SELECT DISTINCT device_type AS v FROM events WHERE #{base_where} AND device_type != '' ORDER BY v"
    }

    # Static options that don't need a query
    static = %{
      "intents" => ~w(buying engaging researching comparing support returning browsing bot),
      "event_types" => ~w(pageview custom)
    }

    dynamic =
      Enum.reduce(queries, %{}, fn {key, sql}, acc ->
        case ClickHouse.query(sql) do
          {:ok, rows} -> Map.put(acc, key, Enum.map(rows, & &1["v"]))
          _ -> Map.put(acc, key, [])
        end
      end)

    Map.merge(dynamic, static)
  end

  defp valid_filter?(%{"field" => f, "op" => op, "value" => v})
       when is_binary(f) and is_binary(op) and is_binary(v) do
    f in @allowed_fields and v != "" and op in ~w(is is_not contains not_contains)
  end

  defp valid_filter?(_), do: false

  # Virtual fields branch first — these need site context. If `site_id`
  # is nil the filter is dropped (returning "") rather than producing an
  # un-scoped subquery that would scan ALL sites' events.
  defp filter_to_sql(%{"field" => "returning", "op" => op, "value" => value}, site_id)
       when not is_nil(site_id) do
    truthy = value in ~w(yes true 1)
    site_p = ClickHouse.param(site_id)

    sub = """
    visitor_id IN (
      SELECT visitor_id FROM events
      WHERE site_id = #{site_p}
        AND event_type = 'pageview' AND ip_is_bot = 0
      GROUP BY visitor_id
      HAVING countDistinct(toDate(timestamp)) > 1
    )
    """

    case {op, truthy} do
      {"is", true} -> "AND #{sub}"
      {"is", false} -> "AND NOT (#{sub})"
      {"is_not", true} -> "AND NOT (#{sub})"
      {"is_not", false} -> "AND #{sub}"
      _ -> ""
    end
  end

  defp filter_to_sql(%{"field" => "returning"}, _site_id), do: ""

  # Direct CH-column filters — same shape as before, just thread site_id
  # through for signature consistency (most clauses ignore it).
  defp filter_to_sql(%{"field" => field, "op" => "is", "value" => value}, _site_id) do
    "AND #{field} = #{ClickHouse.param(value)}"
  end

  defp filter_to_sql(%{"field" => field, "op" => "is_not", "value" => value}, _site_id) do
    "AND #{field} != #{ClickHouse.param(value)}"
  end

  defp filter_to_sql(%{"field" => field, "op" => "contains", "value" => value}, _site_id) do
    escaped = escape_like_wildcards(value)
    "AND #{field} LIKE #{ClickHouse.param("%#{escaped}%")}"
  end

  defp filter_to_sql(%{"field" => field, "op" => "not_contains", "value" => value}, _site_id) do
    escaped = escape_like_wildcards(value)
    "AND #{field} NOT LIKE #{ClickHouse.param("%#{escaped}%")}"
  end

  defp filter_to_sql(_, _site_id), do: ""

  @doc false
  def __virtual_fields__, do: @virtual_fields

  @doc """
  Whether a filter targets a field that needs Postgres pre-resolution.
  `Spectabas.Cohorts` calls this to split filters into CH-direct vs
  PG-resolved buckets before issuing metric queries.
  """
  def pg_resolved?(%{"field" => f}) when is_binary(f), do: f in @pg_resolved_fields
  def pg_resolved?(_), do: false

  @doc "List of fields requiring Postgres pre-resolution."
  def pg_resolved_fields, do: @pg_resolved_fields

  defp escape_like_wildcards(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
