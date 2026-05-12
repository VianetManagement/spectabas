defmodule Spectabas.Workers.ClickElementSnapshot do
  @moduledoc """
  Snapshots top click elements per site into Postgres so the Click Elements
  page doesn't have to hit ClickHouse on every page load / sort / filter.

  Modes:
  - no args → enqueue a per-site job for every site
  - `%{"site_id" => N}` → snapshot one site (the per-site job)

  Per-site job runs one CH query (30-day window, top 1000 elements, clicks >= 2)
  and replaces the rows in `click_element_stats` for that site. Stale rows that
  fell out of the top-1000 are deleted so the registry doesn't grow unbounded.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.{ClickHouse, Goals, Sites}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(300)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id}}) do
    case Sites.get_site(site_id) do
      nil ->
        :ok

      site ->
        snapshot_site(site)
    end
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    Sites.list_sites()
    |> Enum.each(fn site ->
      __MODULE__.new(%{"site_id" => site.id}) |> Oban.insert()
    end)

    :ok
  end

  defp snapshot_site(site) do
    sql = """
    SELECT
      JSONExtractString(properties, '_text') AS element_text,
      replaceRegexpOne(JSONExtractString(properties, '_id'), '-\\d+$', '') AS element_id,
      JSONExtractString(properties, '_tag') AS element_tag,
      any(JSONExtractString(properties, '_href')) AS element_href,
      any(JSONExtractString(properties, '_classes')) AS element_classes,
      count() AS clicks,
      uniq(visitor_id) AS visitors,
      min(timestamp) AS first_seen,
      max(timestamp) AS last_seen,
      groupUniqArray(10)(url_path) AS sample_pages
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND event_type = 'custom'
      AND event_name = '_click'
      AND ip_is_bot = 0
      AND timestamp >= now() - INTERVAL 30 DAY
    GROUP BY element_text, element_id, element_tag
    HAVING clicks >= 2
    ORDER BY clicks DESC
    LIMIT 1000
    SETTINGS max_execution_time = 240
    """

    # CH module default receive_timeout is 30s — way too short for puppies.com
    # volume. Match the SQL max_execution_time above.
    case ClickHouse.query(sql, receive_timeout: 260_000) do
      {:ok, rows} ->
        # CH groups by (text, id, tag) but `element_key` is derived only from
        # id-or-text — two rows with the same id but different tags (e.g.
        # `#submit` clicked as both <button> and <a>) collide on the unique
        # index. Dedupe by key, keeping the first occurrence; rows are sorted
        # by clicks DESC so we keep the most-clicked variant.
        normalized =
          rows
          |> Enum.map(&normalize_row/1)
          |> Enum.uniq_by(& &1["element_key"])

        case Goals.replace_click_element_stats(site, normalized) do
          {:ok, _} ->
            Logger.notice("[ClickElementSnapshot] site=#{site.id} rows=#{length(normalized)}")
            :ok

          {:error, reason} ->
            Logger.error("[ClickElementSnapshot] site=#{site.id} pg_failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("[ClickElementSnapshot] site=#{site.id} ch_failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp normalize_row(row) do
    element_id = to_string(row["element_id"] || "")
    element_text = to_string(row["element_text"] || "")

    key =
      if element_id != "",
        do: "##{element_id}",
        else: "text:#{element_text}"

    %{
      "element_key" => String.slice(key, 0, 512),
      "element_text" => element_text,
      "element_id" => element_id,
      "element_tag" => to_string(row["element_tag"] || ""),
      "element_href" => to_string(row["element_href"] || ""),
      "element_classes" => to_string(row["element_classes"] || ""),
      "clicks" => to_int(row["clicks"]),
      "visitors" => to_int(row["visitors"]),
      "first_seen" => parse_ts(row["first_seen"]),
      "last_seen" => parse_ts(row["last_seen"]),
      "sample_pages" => row["sample_pages"] || []
    }
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_binary(v), do: String.to_integer(v)
  defp to_int(_), do: 0

  defp parse_ts(nil), do: nil
  defp parse_ts(""), do: nil

  defp parse_ts(s) when is_binary(s) do
    case NaiveDateTime.from_iso8601(String.replace(s, " ", "T")) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil
end
