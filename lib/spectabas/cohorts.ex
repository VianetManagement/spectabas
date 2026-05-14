defmodule Spectabas.Cohorts do
  @moduledoc """
  Named, persisted segments of visitors. Cohorts wrap the existing
  `Spectabas.Analytics.Segment` filter language (same field/op/value
  shape) and add a name + visibility + comparison-ready metric queries.

  Two visibility modes:
  - `"private"` — only the creating user sees it
  - `"site"` — everyone with access to the site sees it

  See `Spectabas.Cohorts.Cohort` for the schema and filter validation.
  """

  import Ecto.Query
  alias Spectabas.{Repo, Cohorts.Cohort}

  @doc "Create a cohort. `attrs` is the unwrapped form — filters as a list."
  def create(site_id, user_id, attrs) when is_integer(site_id) do
    attrs
    |> wrap_filters()
    |> Map.merge(%{"site_id" => site_id, "user_id" => user_id})
    |> insert_cohort()
  end

  defp insert_cohort(attrs) do
    %Cohort{}
    |> Cohort.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a cohort. `attrs` is the unwrapped form."
  def update(%Cohort{} = cohort, attrs) do
    cohort
    |> Cohort.changeset(wrap_filters(attrs))
    |> Repo.update()
  end

  @doc "Delete a cohort by id with a site_id check (404-safety)."
  def delete(site_id, cohort_id) do
    case get_for_site(site_id, cohort_id) do
      nil -> {:error, :not_found}
      cohort -> Repo.delete(cohort)
    end
  end

  @doc """
  List cohorts visible to a given user on a site. Includes:
  - All `"site"`-visibility cohorts for that site
  - The user's own `"private"` cohorts for that site
  """
  def list_for_user(site_id, user_id) do
    from(c in Cohort,
      where: c.site_id == ^site_id,
      where: c.visibility == "site" or c.user_id == ^user_id,
      order_by: [asc: c.name]
    )
    |> Repo.all()
  end

  @doc "Fetch a single cohort by id, scoped to site for safety."
  def get_for_site(site_id, cohort_id) do
    Repo.get_by(Cohort, id: cohort_id, site_id: site_id)
  end

  @doc """
  Convert a cohort to a ClickHouse WHERE clause via the existing Segment
  SQL builder. Returns an empty string for a cohort with no filters
  (which means "all visitors").
  """
  def to_sql(%Cohort{} = cohort) do
    Spectabas.Analytics.Segment.to_sql(Cohort.filters_list(cohort))
  end

  @doc """
  Load the standard set of cohort metrics for the detail + compare
  views. Returns a map of:
    %{
      stats: %{visitors:, pageviews:, bounce_rate:, avg_duration:},
      top_pages: [...],
      top_sources: [...],
      conversion_rate_by_goal: %{goal_id => %{name:, completers:, rate:}},
      truncated: boolean — true if a PG-resolved field hit the cap
    }

  Filters route through Analytics functions via two channels:
  - CH-direct filters (everything in `Segment.@allowed_fields` minus
    the PG-resolved set) go through the existing `:segment` opt
  - PG-resolved filters (`scraper_whitelisted`, `identified`) are
    pre-resolved here into a visitor_id list and passed through
    `:cohort_visitor_ids`, which the Analytics `segment_sql/2` helper
    appends as `AND visitor_id IN (...)`

  Range defaults to last 30 days. Visitor-id IN list is capped at 10k —
  beyond that the IN clause gets unwieldy. Hits the cap → returns
  `truncated: true` for the UI to warn about.
  """
  @visitor_id_cap 10_000

  def metrics(%Cohort{} = cohort, user, opts \\ []) do
    site = Spectabas.Sites.get_site!(cohort.site_id)
    period = Keyword.get(opts, :period, :month)
    all_filters = Cohort.filters_list(cohort)

    {pg_filters, ch_filters} =
      Enum.split_with(all_filters, &Spectabas.Analytics.Segment.pg_resolved?/1)

    {visitor_ids, truncated} = resolve_pg_filters(site, pg_filters)

    seg_opts = build_seg_opts(ch_filters, visitor_ids)

    stats =
      case Spectabas.Analytics.overview_stats_fast(site, user, period, seg_opts) do
        {:ok, s} -> s
        _ -> %{}
      end

    top_pages =
      case Spectabas.Analytics.top_pages(site, user, period, seg_opts) do
        {:ok, rows} -> Enum.take(rows, 10)
        _ -> []
      end

    top_sources =
      case Spectabas.Analytics.top_sources(site, user, period, seg_opts) do
        {:ok, rows} -> Enum.take(rows, 10)
        _ -> []
      end

    conversion_rate_by_goal =
      case Spectabas.Analytics.goal_completions(site, user, period, seg_opts) do
        {:ok, rows} ->
          Map.new(rows, fn row ->
            {row.goal_id,
             %{name: row.name, completers: row.unique_completers, rate: row.conversion_rate}}
          end)

        _ ->
          %{}
      end

    %{
      stats: stats,
      top_pages: top_pages,
      top_sources: top_sources,
      conversion_rate_by_goal: conversion_rate_by_goal,
      truncated: truncated
    }
  end

  defp build_seg_opts(ch_filters, nil), do: [segment: ch_filters]
  defp build_seg_opts(ch_filters, ids), do: [segment: ch_filters, cohort_visitor_ids: ids]

  # Resolves PG-derived filter rows (scraper_whitelisted / identified) to
  # a visitor_id list. Returns `{nil, false}` if no PG filters fired
  # (Analytics layer treats nil as "no constraint"). Returns
  # `{ids_list, truncated?}` if PG filters fired.
  defp resolve_pg_filters(_site, []), do: {nil, false}

  defp resolve_pg_filters(site, pg_filters) do
    import Ecto.Query

    # Build a single PG query that ANDs all the PG-resolved predicates
    # so the visitor must satisfy every one of them.
    base = from(v in Spectabas.Visitors.Visitor, where: v.site_id == ^site.id)

    query = Enum.reduce(pg_filters, base, &apply_pg_filter/2)

    # Cap + 1 so we can detect "truncated" without a separate count.
    ids =
      query
      |> select([v], v.id)
      |> limit(^(@visitor_id_cap + 1))
      |> Spectabas.Repo.all()
      |> Enum.map(&to_string/1)

    if length(ids) > @visitor_id_cap do
      {Enum.take(ids, @visitor_id_cap), true}
    else
      {ids, false}
    end
  end

  defp apply_pg_filter(%{"field" => "scraper_whitelisted", "op" => op, "value" => value}, q) do
    truthy = value in ~w(yes true 1)
    want = truthy_for_op(op, truthy)
    import Ecto.Query
    where(q, [v], v.scraper_whitelisted == ^want)
  end

  defp apply_pg_filter(%{"field" => "identified", "op" => op, "value" => value}, q) do
    truthy = value in ~w(yes true 1)
    want = truthy_for_op(op, truthy)
    import Ecto.Query

    if want do
      where(q, [v], not is_nil(v.email) and v.email != "")
    else
      where(q, [v], is_nil(v.email) or v.email == "")
    end
  end

  defp apply_pg_filter(_, q), do: q

  defp truthy_for_op("is", t), do: t
  defp truthy_for_op("is_not", t), do: not t
  defp truthy_for_op(_, t), do: t

  # Accept either the unwrapped form (`%{"filters" => [...]}`) or a raw
  # filter list at the top level. Normalize to the wrapped storage shape.
  defp wrap_filters(%{"filters" => filters} = attrs) when is_list(filters) do
    Map.put(attrs, "filters", %{"filters" => filters})
  end

  defp wrap_filters(attrs), do: attrs
end
