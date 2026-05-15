defmodule Spectabas.Logs.Analytics do
  @moduledoc """
  ClickHouse queries against the `server_logs` table. All queries are
  scoped by `site_id` and clamped by the site's `logs_retention_days`
  so we don't return data older than the customer's configured window
  (CH-side TTL keeps 30 days, but customers can shorten the visible
  range to 1-30 days).

  Filters supported across most query functions:

    * `level: "error" | "warning" | ...` — single-level filter
    * `service: "<source>"` — limits to one app/source label
    * `q: "..."` — substring search across message
    * `hours: N` — time window in hours (defaults to retention cap)

  Returns are always normalized to maps with stringified keys (CH
  returns JSON strings; downstream code wraps numerics with
  `Spectabas.TypeHelpers.to_int/1` where arithmetic is needed).
  """

  alias Spectabas.ClickHouse

  @doc """
  Top-level counts for the dashboard KPI strip. Returns a map with
  `:total`, `:errors`, `:warnings`, `:services`, `:error_groups`.
  """
  def kpi_summary(site_id, opts \\ []) do
    window = window_clause(site_id, opts)

    sql = """
    SELECT
      count() AS total,
      countIf(level IN ('error', 'critical')) AS errors,
      countIf(level = 'warning') AS warnings,
      uniqExact(source) AS services,
      uniqExactIf(error_fingerprint, error_fingerprint != '') AS error_groups
    FROM server_logs
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND #{window}
    """

    case ClickHouse.query(sql) do
      {:ok, [row]} ->
        %{
          total: to_int(row["total"]),
          errors: to_int(row["errors"]),
          warnings: to_int(row["warnings"]),
          services: to_int(row["services"]),
          error_groups: to_int(row["error_groups"])
        }

      _ ->
        %{total: 0, errors: 0, warnings: 0, services: 0, error_groups: 0}
    end
  end

  @doc """
  Hourly log volume bucketed by level, for the timeline chart.
  Returns a list of `%{bucket: iso_string, level: "...", count: N}`.
  """
  def volume_by_level_hourly(site_id, opts \\ []) do
    window = window_clause(site_id, opts)

    sql = """
    SELECT
      toString(toStartOfHour(timestamp)) AS bucket,
      level AS level,
      count() AS count
    FROM server_logs
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND #{window}
    GROUP BY bucket, level
    ORDER BY bucket
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.map(rows, fn r ->
          %{bucket: r["bucket"], level: r["level"], count: to_int(r["count"])}
        end)

      _ ->
        []
    end
  end

  @doc """
  Most recent log lines matching filters, paginated. Returns a list
  of row maps with all `server_logs` columns. Newest first.
  """
  def recent_logs(site_id, opts \\ []) do
    window = window_clause(site_id, opts)
    filters = filter_clauses(opts)
    limit = min(opts[:limit] || 100, 500)
    offset = max(opts[:offset] || 0, 0)

    sql = """
    SELECT
      toString(timestamp) AS timestamp,
      level,
      message,
      source,
      host,
      request_id,
      error_fingerprint,
      elixir_error_module,
      elixir_error_line
    FROM server_logs
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND #{window}
      #{filters}
    ORDER BY timestamp DESC
    LIMIT #{limit} OFFSET #{offset}
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc """
  Groups error lines by `error_fingerprint`. Returns the top N groups
  by count, including first/last seen + a sample message + module/line.
  Filters by message search + service are honored.
  """
  def error_groups(site_id, opts \\ []) do
    window = window_clause(site_id, opts)
    filters = filter_clauses(opts) |> remove_level_filter()
    limit = min(opts[:limit] || 50, 200)

    sql = """
    SELECT
      error_fingerprint AS fingerprint,
      count() AS count,
      toString(min(timestamp)) AS first_seen,
      toString(max(timestamp)) AS last_seen,
      any(elixir_error_module) AS module,
      any(elixir_error_line) AS line,
      any(message) AS sample_message,
      any(source) AS sample_source
    FROM server_logs
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND error_fingerprint != ''
      AND level IN ('error', 'critical')
      AND #{window}
      #{filters}
    GROUP BY error_fingerprint
    ORDER BY count DESC
    LIMIT #{limit}
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.map(rows, fn r ->
          %{
            fingerprint: r["fingerprint"],
            count: to_int(r["count"]),
            first_seen: r["first_seen"],
            last_seen: r["last_seen"],
            module: r["module"],
            line: to_int(r["line"]),
            sample_message: r["sample_message"],
            sample_source: r["sample_source"]
          }
        end)

      _ ->
        []
    end
  end

  @doc """
  Recent lines belonging to one error group (for the expand-row UI
  on the Error Groups tab).
  """
  def logs_for_fingerprint(site_id, fingerprint, opts \\ []) do
    window = window_clause(site_id, opts)
    limit = min(opts[:limit] || 20, 100)

    sql = """
    SELECT
      toString(timestamp) AS timestamp,
      level,
      message,
      source,
      host,
      request_id
    FROM server_logs
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND error_fingerprint = #{ClickHouse.param(fingerprint)}
      AND #{window}
    ORDER BY timestamp DESC
    LIMIT #{limit}
    """

    case ClickHouse.query(sql) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc """
  All distinct service/source labels seen in the window. Used to
  populate the "Service" filter dropdown.
  """
  def top_services(site_id, opts \\ []) do
    window = window_clause(site_id, opts)

    sql = """
    SELECT
      source,
      count() AS count
    FROM server_logs
    WHERE site_id = #{ClickHouse.param(site_id)}
      AND source != ''
      AND #{window}
    GROUP BY source
    ORDER BY count DESC
    LIMIT 50
    """

    case ClickHouse.query(sql) do
      {:ok, rows} ->
        Enum.map(rows, fn r -> %{source: r["source"], count: to_int(r["count"])} end)

      _ ->
        []
    end
  end

  # ---- Helpers ----

  # Time-window WHERE clause that respects site.logs_retention_days.
  # If `:hours` is set, use it (clamped to retention). Otherwise use
  # the full retention window.
  defp window_clause(site_id, opts) do
    retention_hours = retention_hours_for(site_id)
    requested = opts[:hours] || retention_hours
    hours = min(requested, retention_hours)
    "timestamp >= now() - INTERVAL #{hours} HOUR"
  end

  defp retention_hours_for(site_id) do
    case Spectabas.Repo.get(Spectabas.Sites.Site, site_id) do
      %{logs_retention_days: days} when is_integer(days) and days > 0 -> days * 24
      _ -> 14 * 24
    end
  rescue
    _ -> 14 * 24
  end

  defp filter_clauses(opts) do
    [
      level_filter(opts[:level]),
      service_filter(opts[:service]),
      search_filter(opts[:q])
    ]
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ""
      list -> "AND " <> Enum.join(list, " AND ")
    end
  end

  defp level_filter(nil), do: ""
  defp level_filter(""), do: ""
  defp level_filter("all"), do: ""

  defp level_filter(level) when is_binary(level),
    do: "level = #{ClickHouse.param(level)}"

  defp service_filter(nil), do: ""
  defp service_filter(""), do: ""
  defp service_filter("all"), do: ""

  defp service_filter(svc) when is_binary(svc),
    do: "source = #{ClickHouse.param(svc)}"

  defp search_filter(nil), do: ""
  defp search_filter(""), do: ""

  defp search_filter(q) when is_binary(q) do
    escaped = String.replace(q, "%", "\\%") |> String.replace("_", "\\_")
    "positionCaseInsensitive(message, #{ClickHouse.param(escaped)}) > 0"
  end

  # filter_clauses/1 is shared by `recent_logs` and `error_groups`,
  # but error_groups already restricts to error/critical so we don't
  # want a user-selected level (e.g. "info") to wipe out the group
  # query. Strip any `level = ...` clauses for that path.
  defp remove_level_filter(""), do: ""

  defp remove_level_filter("AND " <> rest) do
    parts =
      rest
      |> String.split(" AND ")
      |> Enum.reject(&String.starts_with?(&1, "level "))

    if parts == [], do: "", else: "AND " <> Enum.join(parts, " AND ")
  end

  defp remove_level_filter(other), do: other

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_float(n), do: trunc(n)

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp to_int(_), do: 0
end
