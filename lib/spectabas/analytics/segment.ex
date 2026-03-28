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
    "AND #{field} LIKE #{ClickHouse.param("%#{value}%")}"
  end

  defp filter_to_sql(%{"field" => field, "op" => "not_contains", "value" => value}) do
    "AND #{field} NOT LIKE #{ClickHouse.param("%#{value}%")}"
  end

  defp filter_to_sql(_), do: ""
end
