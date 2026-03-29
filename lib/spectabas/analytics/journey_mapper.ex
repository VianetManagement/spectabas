defmodule Spectabas.Analytics.JourneyMapper do
  @moduledoc """
  Computes the most common visitor journeys (multi-step page paths)
  from ClickHouse session data. Returns ranked paths with visitor
  counts and conversion rates.
  """

  alias Spectabas.{ClickHouse, Accounts}
  alias Spectabas.Sites.Site
  alias Spectabas.Accounts.User

  @conversion_pages ~w(/pricing /signup /register /checkout /subscribe /contact /demo)

  @doc """
  Get the top visitor journeys for a site in a date range.
  A journey is the ordered sequence of page paths in a session.
  Returns {:ok, [journey]} where each journey has :path, :visitors, :converted.
  """
  def top_journeys(%Site{} = site, %User{} = user, date_range, opts \\ []) do
    date_range = ensure_date_range(date_range)
    max_steps = Keyword.get(opts, :max_steps, 5)
    limit = Keyword.get(opts, :limit, 15)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        journey,
        count() AS visitors,
        steps
      FROM (
        SELECT
          session_id,
          groupArray(url_path) AS pages,
          length(groupArray(url_path)) AS steps,
          arrayStringConcat(
            arraySlice(groupArray(url_path), 1, #{max_steps}),
            ' → '
          ) AS journey
        FROM (
          SELECT session_id, url_path, timestamp
          FROM events
          WHERE site_id = #{ClickHouse.param(site.id)}
            AND event_type = 'pageview'
            AND timestamp >= #{ClickHouse.param(fmt(date_range.from))}
            AND timestamp <= #{ClickHouse.param(fmt(date_range.to))}
          ORDER BY session_id, timestamp
        )
        GROUP BY session_id
        HAVING steps >= 2
      )
      GROUP BY journey, steps
      ORDER BY visitors DESC
      LIMIT #{limit}
      """

      case ClickHouse.query(sql) do
        {:ok, rows} ->
          journeys =
            Enum.map(rows, fn row ->
              journey_str = row["journey"] || ""
              pages = String.split(journey_str, " → ")

              %{
                path: journey_str,
                pages: pages,
                visitors: to_int(row["visitors"]),
                steps: to_int(row["steps"]),
                ends_at_conversion: ends_at_conversion?(pages),
                conversion_page: find_conversion_page(pages)
              }
            end)

          {:ok, journeys}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Get journey stats: total sessions, multi-page sessions, avg steps, conversion rate.
  """
  def journey_stats(%Site{} = site, %User{} = user, date_range) do
    date_range = ensure_date_range(date_range)

    with :ok <- authorize(site, user) do
      sql = """
      SELECT
        count() AS total_sessions,
        countIf(pv >= 2) AS multi_page_sessions,
        round(avg(pv), 1) AS avg_pages_per_session,
        countIf(has_conversion = 1) AS converting_sessions
      FROM (
        SELECT
          session_id,
          countIf(event_type = 'pageview') AS pv,
          maxIf(1, url_path IN (#{conversion_pages_sql()})) AS has_conversion
        FROM events
        WHERE site_id = #{ClickHouse.param(site.id)}
          AND timestamp >= #{ClickHouse.param(fmt(date_range.from))}
          AND timestamp <= #{ClickHouse.param(fmt(date_range.to))}
        GROUP BY session_id
      )
      """

      case ClickHouse.query(sql) do
        {:ok, [row]} -> {:ok, row}
        {:ok, []} -> {:ok, %{}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ends_at_conversion?(pages) when is_list(pages) do
    last = List.last(pages) || ""
    Enum.any?(@conversion_pages, &String.contains?(String.downcase(last), &1))
  end

  defp find_conversion_page(pages) when is_list(pages) do
    Enum.find(pages, fn page ->
      Enum.any?(@conversion_pages, &String.contains?(String.downcase(page), &1))
    end)
  end

  defp conversion_pages_sql do
    @conversion_pages
    |> Enum.map(&ClickHouse.param(&1))
    |> Enum.join(", ")
  end

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

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_int(_), do: 0
end
