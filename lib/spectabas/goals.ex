defmodule Spectabas.Goals do
  @moduledoc """
  Context for managing goals and funnels.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Goals.{Goal, Funnel, ClickElementName}
  alias Spectabas.Analytics

  @doc """
  Create a goal for a site.
  """
  def create_goal(site, attrs) do
    %Goal{}
    |> Goal.changeset(Map.put(attrs, "site_id", site.id))
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

  def get_funnel_for_site!(site, funnel_id) do
    Repo.one!(from(f in Funnel, where: f.id == ^funnel_id and f.site_id == ^site.id))
  end

  def get_goal_for_site!(site, goal_id) do
    Repo.one!(from(g in Goal, where: g.id == ^goal_id and g.site_id == ^site.id))
  end

  def goals_referencing_element(site, element_key) do
    Repo.all(
      from(g in Goal,
        where:
          g.site_id == ^site.id and g.goal_type == "click_element" and
            g.element_selector == ^element_key
      )
    )
  end

  def funnels_referencing_element(site, element_key) do
    funnels = list_funnels(site)

    Enum.filter(funnels, fn funnel ->
      Enum.any?(funnel.steps || [], fn step ->
        step["type"] == "click_element" and step["value"] == element_key
      end)
    end)
  end

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

  def check_goal(%Goal{goal_type: "click_element", element_selector: selector}, _site, event) do
    event_name = Map.get(event, :event_name, Map.get(event, "event_name", ""))
    props = Map.get(event, :props, Map.get(event, "props", %{}))

    event_name == "_click" && element_matches?(selector, props)
  end

  def check_goal(_, _, _), do: false

  @doc """
  Create a funnel for a site.
  """
  def create_funnel(site, attrs) do
    %Funnel{}
    |> Funnel.changeset(Map.put(attrs, "site_id", site.id))
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
  Delegates to Analytics.funnel_stats/4.
  """
  def evaluate_funnel(site, user, funnel) do
    Analytics.funnel_stats(site, user, funnel)
  end

  # --- Click Element Names ---

  def list_element_names(site) do
    Repo.all(
      from(n in ClickElementName,
        where: n.site_id == ^site.id,
        order_by: [asc: n.friendly_name]
      )
    )
  end

  def element_names_map(site) do
    list_element_names(site)
    |> Map.new(fn n -> {n.element_key, n} end)
  end

  def upsert_element_name(site, attrs) do
    key = attrs["element_key"] || Map.get(attrs, :element_key)

    case Repo.one(
           from(n in ClickElementName, where: n.site_id == ^site.id and n.element_key == ^key)
         ) do
      nil ->
        %ClickElementName{}
        |> ClickElementName.changeset(Map.put(attrs, "site_id", site.id))
        |> Repo.insert()

      existing ->
        existing
        |> ClickElementName.changeset(attrs)
        |> Repo.update()
    end
  end

  def ignore_element(site, element_key) do
    case Repo.one(
           from(n in ClickElementName,
             where: n.site_id == ^site.id and n.element_key == ^element_key
           )
         ) do
      nil ->
        %ClickElementName{}
        |> ClickElementName.changeset(%{
          "site_id" => site.id,
          "element_key" => element_key,
          "friendly_name" => element_key,
          "ignored" => true
        })
        |> Repo.insert()

      existing ->
        existing
        |> ClickElementName.changeset(%{"ignored" => !existing.ignored})
        |> Repo.update()
    end
  end

  # --- Private helpers ---

  defp element_matches?(selector, props) when is_binary(selector) and is_map(props) do
    cond do
      String.starts_with?(selector, "#") ->
        Map.get(props, "_id", Map.get(props, :_id, "")) == String.slice(selector, 1..-1//1)

      String.starts_with?(selector, "text:") ->
        pattern = String.slice(selector, 5..-1//1)
        text = Map.get(props, "_text", Map.get(props, :_text, ""))
        if String.contains?(pattern, "*"), do: path_matches?(pattern, text), else: text == pattern

      true ->
        false
    end
  end

  defp element_matches?(_, _), do: false

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
