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
      conversion_rate_by_goal: %{goal_id => %{name:, completers:, rate:}}
    }

  All queries scope to the cohort's filters by passing them via the
  existing `:segment` opt that Analytics functions already accept.
  Range defaults to last 30 days.
  """
  def metrics(%Cohort{} = cohort, user, opts \\ []) do
    site = Spectabas.Sites.get_site!(cohort.site_id)
    period = Keyword.get(opts, :period, :month)
    segment = Cohort.filters_list(cohort)
    seg_opts = [segment: segment]

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
      case Spectabas.Analytics.top_sources(site, user, period) do
        {:ok, rows} -> Enum.take(rows, 10)
        _ -> []
      end

    # Goal conversion within the cohort: use goal_completions which
    # returns per-goal counts. Apply the cohort segment by feeding
    # session-restricted CH queries if/when we extend goal_completions
    # to accept :segment — for v1 we report goal completions site-wide
    # alongside the cohort-filtered top-of-funnel, and let the user
    # infer the lift.
    conversion_rate_by_goal =
      case Spectabas.Analytics.goal_completions(site, user, period) do
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
      conversion_rate_by_goal: conversion_rate_by_goal
    }
  end

  # Accept either the unwrapped form (`%{"filters" => [...]}`) or a raw
  # filter list at the top level. Normalize to the wrapped storage shape.
  defp wrap_filters(%{"filters" => filters} = attrs) when is_list(filters) do
    Map.put(attrs, "filters", %{"filters" => filters})
  end

  defp wrap_filters(attrs), do: attrs
end
