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
    ip_country ip_country_name ip_region_name ip_city ip_timezone
    ip_asn ip_org
    browser os device_type
    referrer_domain utm_source utm_medium utm_campaign
    url_path url_host
    event_type event_name
    visitor_intent
  )

  @doc """
  Convert a list of segment filters into a ClickHouse WHERE clause string.
  Returns an empty string if filters is nil or empty.
  """
  def to_sql(nil), do: ""
  def to_sql([]), do: ""

  def to_sql(filters) when is_list(filters) do
    clauses =
      filters
      |> Enum.filter(&valid_filter?/1)
      |> Enum.map(&filter_to_sql/1)
      |> Enum.reject(&(&1 == ""))

    case clauses do
      [] -> ""
      _ -> Enum.join(clauses, "\n    ")
    end
  end

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

  defp filter_to_sql(%{"field" => field, "op" => "is", "value" => value}) do
    "AND #{field} = #{ClickHouse.param(value)}"
  end

  defp filter_to_sql(%{"field" => field, "op" => "is_not", "value" => value}) do
    "AND #{field} != #{ClickHouse.param(value)}"
  end

  defp filter_to_sql(%{"field" => field, "op" => "contains", "value" => value}) do
    escaped = escape_like_wildcards(value)
    "AND #{field} LIKE #{ClickHouse.param("%#{escaped}%")}"
  end

  defp filter_to_sql(%{"field" => field, "op" => "not_contains", "value" => value}) do
    escaped = escape_like_wildcards(value)
    "AND #{field} NOT LIKE #{ClickHouse.param("%#{escaped}%")}"
  end

  defp filter_to_sql(_), do: ""

  defp escape_like_wildcards(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
