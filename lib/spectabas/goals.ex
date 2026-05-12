defmodule Spectabas.Goals do
  @moduledoc """
  Context for managing goals and funnels.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Goals.{Goal, Funnel, ClickElementName, ClickElementStat, GoalStat, FunnelStat}
  alias Spectabas.Analytics

  @doc """
  Create a goal for a site.
  """
  def create_goal(site, attrs) do
    result =
      %Goal{}
      |> Goal.changeset(Map.put(attrs, "site_id", site.id))
      |> Repo.insert()

    case result do
      {:ok, _} ->
        Spectabas.Workers.GoalStatsSnapshot.new(%{"site_id" => site.id}) |> Oban.insert()
        result

      _ ->
        result
    end
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
      nil ->
        {:error, :not_found}

      goal ->
        result = Repo.delete(goal)

        # Drop the goal detail snapshot row so a deleted goal doesn't linger
        # in dashboard_snapshots forever.
        from(s in "dashboard_snapshots",
          where: s.site_id == ^site.id and s.kind == ^"goal_detail:#{goal_id}"
        )
        |> Repo.delete_all()

        result
    end
  end

  @doc """
  Get a single goal by ID. Raises if not found.
  """
  def get_goal!(id), do: Repo.get!(Goal, id)

  def update_funnel(funnel, attrs) do
    funnel
    |> Funnel.changeset(attrs)
    |> Repo.update()
  end

  def delete_funnel(site, funnel_id) do
    case Repo.one(from(f in Funnel, where: f.id == ^funnel_id and f.site_id == ^site.id)) do
      nil -> {:error, :not_found}
      funnel -> Repo.delete(funnel)
    end
  end

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
    result =
      %Funnel{}
      |> Funnel.changeset(Map.put(attrs, "site_id", site.id))
      |> Repo.insert()

    case result do
      {:ok, _} ->
        Spectabas.Workers.FunnelStatsSnapshot.new(%{"site_id" => site.id}) |> Oban.insert()
        result

      _ ->
        result
    end
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

  # --- Click Element Stats (Postgres snapshot) ---

  @doc """
  List snapshotted click element stats for a site.

  Postgres-backed mirror of the top click elements seen in the last 30 days.
  Populated by `Spectabas.Workers.ClickElementSnapshot` hourly.

  Opts: `:tag_filter`, `:search`, `:sort_by` (clicks|visitors|first_seen|last_seen),
  `:sort_dir` (asc|desc).
  """
  def list_click_element_stats(site, opts \\ []) do
    sort_col =
      case Keyword.get(opts, :sort_by, "clicks") do
        s when s in ~w(clicks visitors first_seen last_seen) -> String.to_existing_atom(s)
        _ -> :clicks
      end

    sort_dir =
      if Keyword.get(opts, :sort_dir, "DESC") |> to_string() |> String.upcase() == "ASC",
        do: :asc,
        else: :desc

    query =
      from(s in ClickElementStat,
        where: s.site_id == ^site.id,
        order_by: [{^sort_dir, field(s, ^sort_col)}],
        limit: 500
      )

    query =
      case Keyword.get(opts, :tag_filter) do
        nil -> query
        "" -> query
        tag -> from(s in query, where: s.element_tag == ^tag)
      end

    query =
      case Keyword.get(opts, :search) do
        s when is_binary(s) and s != "" ->
          escaped =
            s
            |> String.replace("\\", "\\\\")
            |> String.replace("%", "\\%")
            |> String.replace("_", "\\_")

          pat = "%#{escaped}%"

          from(r in query,
            where:
              ilike(r.element_text, ^pat) or ilike(r.element_id, ^pat) or
                ilike(r.element_classes, ^pat) or ilike(r.element_href, ^pat)
          )

        _ ->
          query
      end

    Repo.all(query)
  end

  @doc """
  Upsert a batch of click element stats rows for a site.

  Rows is a list of maps with string keys matching the schema fields. Uses
  ON CONFLICT (site_id, element_key) so it's safe to re-run.
  """
  def upsert_click_element_stats(_site, []), do: {:ok, 0}

  def upsert_click_element_stats(site, rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(rows, fn r ->
        %{
          site_id: site.id,
          element_key: r["element_key"] || r[:element_key],
          element_text: r["element_text"] || r[:element_text],
          element_id: r["element_id"] || r[:element_id],
          element_tag: r["element_tag"] || r[:element_tag],
          element_href: r["element_href"] || r[:element_href],
          element_classes: r["element_classes"] || r[:element_classes],
          clicks: r["clicks"] || r[:clicks] || 0,
          visitors: r["visitors"] || r[:visitors] || 0,
          first_seen: r["first_seen"] || r[:first_seen],
          last_seen: r["last_seen"] || r[:last_seen],
          sample_pages: r["sample_pages"] || r[:sample_pages] || [],
          refreshed_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(ClickElementStat, entries,
        on_conflict:
          {:replace,
           [
             :element_text,
             :element_id,
             :element_tag,
             :element_href,
             :element_classes,
             :clicks,
             :visitors,
             :first_seen,
             :last_seen,
             :sample_pages,
             :refreshed_at
           ]},
        conflict_target: [:site_id, :element_key]
      )

    {:ok, count}
  end

  @doc """
  Replace the site's click element snapshot with a fresh set of rows.

  Deletes any keys that no longer appear in the latest snapshot so dead
  elements don't linger forever.
  """
  # Empty `rows` would translate to `WHERE element_key NOT IN ()` which Ecto
  # rewrites to `true`, wiping the whole site's snapshot. Guard against that —
  # if the CH query returned no rows (likely a timeout or hiccup), preserve
  # existing data and let the next cron retry.
  def replace_click_element_stats(_site, []), do: {:ok, 0}

  def replace_click_element_stats(site, rows) when is_list(rows) do
    keys = Enum.map(rows, fn r -> r["element_key"] || r[:element_key] end)

    Repo.transaction(fn ->
      from(s in ClickElementStat,
        where: s.site_id == ^site.id and s.element_key not in ^keys
      )
      |> Repo.delete_all()

      upsert_click_element_stats(site, rows)
    end)
  end

  @doc """
  Most-recent `refreshed_at` for the site's snapshot, or nil if never refreshed.
  """
  def click_element_stats_last_refreshed_at(site) do
    Repo.one(
      from(s in ClickElementStat,
        where: s.site_id == ^site.id,
        select: max(s.refreshed_at)
      )
    )
  end

  # --- Goal stats snapshot ---

  @doc """
  Map of goal_id => GoalStat for a site. Used by the Goals dashboard to render
  completions / unique visitors / conversion rate without hitting ClickHouse.
  """
  def goal_stats_map(site) do
    Repo.all(from(s in GoalStat, where: s.site_id == ^site.id))
    |> Map.new(fn s -> {s.goal_id, s} end)
  end

  @doc """
  Replace the snapshot rows for every goal on the site. `rows` is a list of
  maps keyed by goal_id with the full set of fields. Goals not present in
  `rows` are deleted (so dashboard doesn't show stale stats for removed goals).
  """
  def replace_goal_stats(site, rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    goal_ids = Enum.map(rows, & &1[:goal_id])

    entries =
      Enum.map(rows, fn r ->
        %{
          site_id: site.id,
          goal_id: r[:goal_id],
          completions: r[:completions] || 0,
          unique_completers: r[:unique_completers] || 0,
          conversion_rate: r[:conversion_rate] || 0.0,
          total_visitors: r[:total_visitors] || 0,
          top_sources: r[:top_sources] || [],
          window_days: r[:window_days] || 7,
          refreshed_at: now
        }
      end)

    Repo.transaction(fn ->
      from(s in GoalStat,
        where: s.site_id == ^site.id and s.goal_id not in ^goal_ids
      )
      |> Repo.delete_all()

      if entries != [] do
        Repo.insert_all(GoalStat, entries,
          on_conflict:
            {:replace,
             [
               :completions,
               :unique_completers,
               :conversion_rate,
               :total_visitors,
               :top_sources,
               :window_days,
               :refreshed_at
             ]},
          conflict_target: [:goal_id]
        )
      end

      :ok
    end)
  end

  def goal_stats_last_refreshed_at(site) do
    Repo.one(from(s in GoalStat, where: s.site_id == ^site.id, select: max(s.refreshed_at)))
  end

  # --- Funnel stats snapshot ---

  @doc """
  Map of funnel_id => FunnelStat for a site.
  """
  def funnel_stats_map(site) do
    Repo.all(from(s in FunnelStat, where: s.site_id == ^site.id))
    |> Map.new(fn s -> {s.funnel_id, s} end)
  end

  def replace_funnel_stats(site, rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    funnel_ids = Enum.map(rows, & &1[:funnel_id])

    entries =
      Enum.map(rows, fn r ->
        %{
          site_id: site.id,
          funnel_id: r[:funnel_id],
          entered: r[:entered] || 0,
          completed: r[:completed] || 0,
          conversion_rate: r[:conversion_rate] || 0.0,
          window_days: r[:window_days] || 30,
          refreshed_at: now
        }
      end)

    Repo.transaction(fn ->
      from(s in FunnelStat,
        where: s.site_id == ^site.id and s.funnel_id not in ^funnel_ids
      )
      |> Repo.delete_all()

      if entries != [] do
        Repo.insert_all(FunnelStat, entries,
          on_conflict:
            {:replace, [:entered, :completed, :conversion_rate, :window_days, :refreshed_at]},
          conflict_target: [:funnel_id]
        )
      end

      :ok
    end)
  end

  def funnel_stats_last_refreshed_at(site) do
    Repo.one(from(s in FunnelStat, where: s.site_id == ^site.id, select: max(s.refreshed_at)))
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
