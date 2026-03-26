defmodule Spectabas.Goals do
  @moduledoc """
  Context for managing goals and funnels.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Goals.{Goal, Funnel}
  alias Spectabas.Analytics

  @doc """
  Create a goal for a site.
  """
  def create_goal(site, attrs) do
    %Goal{}
    |> Goal.changeset(Map.put(attrs, :site_id, site.id))
    |> Repo.insert()
  end

  @doc """
  List all goals for a site.
  """
  def list_goals(site) do
    Repo.all(
      from(g in Goal,
        where: g.site_id == ^site.id,
        order_by: [asc: g.name]
      )
    )
  end

  @doc """
  Delete a goal.
  """
  def delete_goal(site, goal_id) do
    case Repo.one(from(g in Goal, where: g.id == ^goal_id and g.site_id == ^site.id)) do
      nil -> {:error, :not_found}
      goal -> Repo.delete(goal)
    end
  end

  @doc """
  Get a single goal by ID. Raises if not found.
  """
  def get_goal!(id), do: Repo.get!(Goal, id)

  @doc """
  Check if an event matches a goal.
  Returns true if the event satisfies the goal's conditions.

  For pageview goals, page_path supports wildcard matching with *.
  For custom_event goals, event_name must match exactly.
  """
  def check_goal(%Goal{goal_type: "pageview", page_path: pattern}, _site, event) do
    path = Map.get(event, :url_path, Map.get(event, "url_path", ""))
    path_matches?(pattern, path)
  end

  def check_goal(%Goal{goal_type: "custom_event", event_name: name}, _site, event) do
    event_name = Map.get(event, :event_name, Map.get(event, "event_name", ""))
    event_name == name
  end

  def check_goal(_, _, _), do: false

  @doc """
  Create a funnel for a site.
  """
  def create_funnel(site, attrs) do
    %Funnel{}
    |> Funnel.changeset(Map.put(attrs, :site_id, site.id))
    |> Repo.insert()
  end

  @doc """
  List all funnels for a site.
  """
  def list_funnels(site) do
    Repo.all(
      from(f in Funnel,
        where: f.site_id == ^site.id,
        order_by: [asc: f.name]
      )
    )
  end

  @doc """
  Evaluate a funnel using ClickHouse windowFunnel().
  Delegates to Analytics.funnel_stats/3.
  """
  def evaluate_funnel(site, user, funnel) do
    Analytics.funnel_stats(site, user, funnel)
  end

  # --- Private helpers ---

  defp path_matches?(pattern, path) when is_binary(pattern) and is_binary(path) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    case Regex.compile("^#{regex}$") do
      {:ok, re} -> Regex.match?(re, path)
      _ -> false
    end
  end

  defp path_matches?(_, _), do: false
end
