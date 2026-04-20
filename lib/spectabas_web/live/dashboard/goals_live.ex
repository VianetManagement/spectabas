defmodule SpectabasWeb.Dashboard.GoalsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Goal tracking — pageview and custom event goal completions."

  alias Spectabas.{Accounts, Sites, Goals, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @write_events ~w(create_goal delete_goal)

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      socket =
        if !Accounts.can_write?(user) do
          attach_hook(socket, :viewer_guard, :handle_event, fn
            event, _params, sock when event in @write_events ->
              {:halt, put_flash(sock, :error, "Viewers have read-only access.")}

            _event, _params, sock ->
              {:cont, sock}
          end)
        else
          socket
        end

      goals = Goals.list_goals(site)

      send(self(), :load_analytics)

      {:ok,
       socket
       |> assign(:page_title, "Goals - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:goals, goals)
       |> assign(:completions, %{})
       |> assign(:source_attribution, %{})
       |> assign(:show_form, false)
       |> assign(:form, to_form(goal_changeset()))
       |> assign(:goal_type, "pageview")
       |> assign(:discovered_elements, [])
       |> assign(:sort_by, "name")
       |> assign(:sort_dir, :asc)}
    end
  end

  @impl true
  def handle_info(:load_analytics, socket) do
    site = socket.assigns.site
    user = socket.assigns.user
    goals = socket.assigns.goals

    # Run completions + source attribution in parallel
    completions_task =
      Task.async(fn ->
        case Analytics.goal_completions(site, user, :week) do
          {:ok, data} -> Map.new(data, fn r -> {r.goal_id, r} end)
          _ -> %{}
        end
      end)

    sources_task = Task.async(fn -> load_source_attribution(goals, site, user) end)

    completions = Task.await(completions_task, 15_000)
    source_attribution = Task.await(sources_task, 15_000)

    {:noreply,
     socket
     |> assign(:completions, completions)
     |> assign(:source_attribution, source_attribution)}
  rescue
    _ -> {:noreply, socket}
  end

  @impl true
  def handle_event("sort", %{"col" => col}, socket) do
    dir =
      if socket.assigns.sort_by == col and socket.assigns.sort_dir == :asc,
        do: :desc,
        else: :asc

    {:noreply, assign(socket, sort_by: col, sort_dir: dir)}
  end

  def handle_event("toggle_form", _params, socket) do
    if socket.assigns.show_form do
      {:noreply, assign(socket, :show_form, false)}
    else
      # Load discovered elements when opening the form
      elements =
        safe_query(fn ->
          Analytics.discovered_click_elements(socket.assigns.site, socket.assigns.user)
        end)

      {:noreply,
       socket
       |> assign(:show_form, true)
       |> assign(:discovered_elements, elements)}
    end
  end

  def handle_event("create_goal", %{"goal" => params}, socket) do
    case Goals.create_goal(socket.assigns.site, params) do
      {:ok, _goal} ->
        goals = Goals.list_goals(socket.assigns.site)
        sources = load_source_attribution(goals, socket.assigns.site, socket.assigns.user)

        {:noreply,
         socket
         |> put_flash(:info, "Goal created.")
         |> assign(:goals, goals)
         |> assign(:source_attribution, sources)
         |> assign(:show_form, false)
         |> assign(:form, to_form(goal_changeset()))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("validate_goal", %{"goal" => params}, socket) do
    goal_type = Map.get(params, "goal_type", socket.assigns.goal_type)

    changeset =
      %Goals.Goal{}
      |> Goals.Goal.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:goal_type, goal_type)}
  end

  def handle_event("select_element", %{"selector" => selector, "name" => name}, socket) do
    changeset =
      %Goals.Goal{}
      |> Goals.Goal.changeset(%{
        "name" => name,
        "goal_type" => "click_element",
        "element_selector" => selector
      })
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:goal_type, "click_element")}
  end

  def handle_event("delete_goal", %{"id" => id}, socket) do
    case Goals.delete_goal(socket.assigns.site, id) do
      {:ok, _} ->
        goals = Goals.list_goals(socket.assigns.site)
        {:noreply, socket |> put_flash(:info, "Goal deleted.") |> assign(:goals, goals)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete goal.")}
    end
  end

  defp element_selector_value(el) do
    id = el["element_id"] |> to_string()
    text = el["element_text"] |> to_string()
    if id != "", do: "##{id}", else: "text:#{text}"
  end

  defp element_goal_name(el) do
    text = el["element_text"] |> to_string() |> String.slice(0..39)
    tag = el["element_tag"] |> to_string() |> String.downcase()

    "Click: #{text}"
    |> String.trim()
    |> then(fn n -> if String.ends_with?(n, ":"), do: "Click #{tag}", else: n end)
  end

  defp element_tag_classes(tag) do
    case to_string(tag) |> String.downcase() do
      "a" -> "bg-blue-100 text-blue-700"
      "button" -> "bg-green-100 text-green-700"
      "input" -> "bg-amber-100 text-amber-700"
      _ -> "bg-gray-100 text-gray-700"
    end
  end

  defp goal_type_classes(type) do
    case type do
      "pageview" -> "bg-blue-100 text-blue-800"
      "custom_event" -> "bg-purple-100 text-purple-800"
      "click_element" -> "bg-green-100 text-green-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end

  defp goal_type_label(type) do
    case type do
      "click_element" -> "click"
      other -> other
    end
  end

  defp sorted_goals(goals, completions, sort_by, sort_dir) do
    sorted =
      Enum.sort_by(goals, fn goal ->
        stats =
          Map.get(completions, goal.id, %{
            completions: 0,
            unique_completers: 0,
            conversion_rate: 0.0
          })

        case sort_by do
          "name" -> goal.name |> String.downcase()
          "type" -> goal.goal_type
          "target" -> goal.page_path || goal.event_name || goal.element_selector || ""
          "completions" -> stats.completions
          "visitors" -> stats.unique_completers
          "conv_rate" -> stats.conversion_rate
          _ -> goal.name |> String.downcase()
        end
      end)

    if sort_dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  defp sort_indicator(col, sort_by, sort_dir) do
    if col == sort_by, do: if(sort_dir == :asc, do: " ↑", else: " ↓"), else: ""
  end

  defp goal_changeset do
    Goals.Goal.changeset(%Goals.Goal{}, %{})
  end

  defp load_source_attribution(goals, site, user) do
    tasks =
      Enum.map(goals, fn goal ->
        Task.async(fn ->
          {goal.id,
           safe_query(fn -> Analytics.goal_source_attribution(site, user, goal, :week) end)
           |> Enum.take(3)}
        end)
      end)

    tasks
    |> Task.await_many(10_000)
    |> Map.new()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Goals"
      page_description="Track pageview and custom event goal completions."
      active="goals"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3 mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Goals</h1>
          </div>
          <button
            phx-click="toggle_form"
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
          >
            {if @show_form, do: "Cancel", else: "New Goal"}
          </button>
        </div>

        <div :if={@show_form} class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Create Goal</h2>
          <.form for={@form} phx-submit="create_goal" phx-change="validate_goal" class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-gray-700">Goal Name</label>
              <input
                type="text"
                name="goal[name]"
                value={@form[:name].value}
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                required
              />
              <p
                :for={msg <- Enum.map(@form[:name].errors, &translate_error/1)}
                class="mt-1 text-sm text-red-600"
              >
                {msg}
              </p>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Goal Type</label>
              <div class="flex flex-wrap gap-4">
                <label
                  :for={
                    {t, label} <- [
                      {"pageview", "Pageview"},
                      {"custom_event", "Custom event"},
                      {"click_element", "Click element"}
                    ]
                  }
                  class="flex items-center gap-2"
                >
                  <input
                    type="radio"
                    name="goal[goal_type]"
                    value={t}
                    checked={@goal_type == t}
                    class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300"
                  />
                  <span class="text-sm text-gray-700">{label}</span>
                </label>
              </div>
            </div>
            <div :if={@goal_type == "pageview"}>
              <label class="block text-sm font-medium text-gray-700">
                Page Path (supports * wildcard)
              </label>
              <input
                type="text"
                name="goal[page_path]"
                value={@form[:page_path].value}
                placeholder="/pricing*"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
              <p
                :for={msg <- Enum.map(@form[:page_path].errors, &translate_error/1)}
                class="mt-1 text-sm text-red-600"
              >
                {msg}
              </p>
            </div>
            <div :if={@goal_type == "custom_event"}>
              <label class="block text-sm font-medium text-gray-700">Event Name</label>
              <input
                type="text"
                name="goal[event_name]"
                value={@form[:event_name].value}
                placeholder="signup_complete"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
              <p
                :for={msg <- Enum.map(@form[:event_name].errors, &translate_error/1)}
                class="mt-1 text-sm text-red-600"
              >
                {msg}
              </p>
            </div>
            <div :if={@goal_type == "click_element"}>
              <label class="block text-sm font-medium text-gray-700">
                Element Selector
              </label>
              <input
                type="text"
                name="goal[element_selector]"
                value={@form[:element_selector].value}
                placeholder="#signup-btn or text:Add to Cart"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
              <p class="mt-1 text-xs text-gray-500">
                Use <code class="bg-gray-100 px-1 rounded">#element-id</code>
                to match by ID,
                or <code class="bg-gray-100 px-1 rounded">text:Button Text</code>
                to match by visible text
                (<code class="bg-gray-100 px-1 rounded">*</code> wildcard supported).
              </p>
              <p
                :for={msg <- Enum.map(@form[:element_selector].errors, &translate_error/1)}
                class="mt-1 text-sm text-red-600"
              >
                {msg}
              </p>

              <%!-- Discovered elements from recent click data --%>
              <div
                :if={@discovered_elements == []}
                class="mt-3 p-3 bg-gray-50 rounded-lg border border-gray-200 text-sm text-gray-500"
              >
                <p class="font-medium text-gray-600 mb-1">No elements detected yet</p>
                <p>
                  Buttons and links on your site will appear here automatically once visitors start clicking them. This typically takes a few hours after the tracker is installed.
                </p>
              </div>
              <div :if={@discovered_elements != []} class="mt-3">
                <p class="text-xs font-medium text-gray-500 uppercase tracking-wider mb-2">
                  Detected on your site (last 30 days)
                </p>
                <div class="space-y-1 max-h-48 overflow-y-auto">
                  <button
                    :for={el <- @discovered_elements}
                    type="button"
                    phx-click="select_element"
                    phx-value-selector={element_selector_value(el)}
                    phx-value-name={element_goal_name(el)}
                    class="w-full text-left px-3 py-2 text-sm rounded-lg border border-gray-200 hover:border-indigo-300 hover:bg-indigo-50 transition-colors flex items-center justify-between gap-2"
                  >
                    <span class="flex items-center gap-2 min-w-0">
                      <span class={[
                        "shrink-0 inline-flex items-center px-1.5 py-0.5 rounded text-xs font-mono",
                        element_tag_classes(el["element_tag"])
                      ]}>
                        {el["element_tag"]}
                      </span>
                      <span class="truncate font-medium text-gray-900">
                        {el["element_text"] |> to_string() |> String.slice(0..59)}
                      </span>
                      <span
                        :if={el["element_id"] != ""}
                        class="shrink-0 text-xs text-gray-400 font-mono"
                      >
                        #{el["element_id"]}
                      </span>
                    </span>
                    <span class="shrink-0 text-xs text-gray-500 tabular-nums">
                      {format_number(to_num(el["clicks"]))} clicks
                    </span>
                  </button>
                </div>
              </div>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Create Goal
              </button>
            </div>
          </.form>
        </div>

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th
                  phx-click="sort"
                  phx-value-col="name"
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
                >
                  Name{sort_indicator("name", @sort_by, @sort_dir)}
                </th>
                <th
                  phx-click="sort"
                  phx-value-col="type"
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
                >
                  Type{sort_indicator("type", @sort_by, @sort_dir)}
                </th>
                <th
                  phx-click="sort"
                  phx-value-col="target"
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
                >
                  Target{sort_indicator("target", @sort_by, @sort_dir)}
                </th>
                <th
                  phx-click="sort"
                  phx-value-col="completions"
                  class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
                >
                  Completions (7d){sort_indicator("completions", @sort_by, @sort_dir)}
                </th>
                <th
                  phx-click="sort"
                  phx-value-col="visitors"
                  class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
                >
                  Unique Visitors{sort_indicator("visitors", @sort_by, @sort_dir)}
                </th>
                <th
                  phx-click="sort"
                  phx-value-col="conv_rate"
                  class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
                >
                  Conv Rate{sort_indicator("conv_rate", @sort_by, @sort_dir)}
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@goals == []}>
                <td colspan="7" class="px-6 py-8 text-center text-gray-500">No goals configured.</td>
              </tr>
              <tr
                :for={goal <- sorted_goals(@goals, @completions, @sort_by, @sort_dir)}
                class="hover:bg-gray-50"
              >
                <td class="px-6 py-4">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/goals/#{goal.id}"}
                    class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
                  >
                    {goal.name}
                  </.link>
                  <div
                    :if={Map.get(@source_attribution, goal.id, []) != []}
                    class="mt-1 text-xs text-gray-500"
                  >
                    Top sources:
                    <span
                      :for={{src, i} <- Enum.with_index(Map.get(@source_attribution, goal.id, []))}
                      class="inline"
                    >
                      <span :if={i > 0}>, </span>
                      <span class="font-medium text-gray-600">{src["source"]}</span>
                      <span class="text-gray-400">({format_number(to_num(src["completers"]))})</span>
                    </span>
                  </div>
                </td>
                <td class="px-6 py-4">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    goal_type_classes(goal.goal_type)
                  ]}>
                    {goal_type_label(goal.goal_type)}
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500 font-mono">
                  {goal.page_path || goal.event_name || goal.element_selector || "-"}
                </td>
                <% stats =
                  Map.get(@completions, goal.id, %{
                    completions: 0,
                    unique_completers: 0,
                    conversion_rate: 0.0
                  }) %>
                <td class="px-6 py-4 text-sm text-gray-900 text-right font-semibold tabular-nums">
                  <%= if @completions == %{} do %>
                    <.death_star_spinner class="w-3 h-3 text-gray-300 inline-block" />
                  <% else %>
                    {format_number(stats.completions)}
                  <% end %>
                </td>
                <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                  <%= if @completions == %{} do %>
                    <.death_star_spinner class="w-3 h-3 text-gray-300 inline-block" />
                  <% else %>
                    {format_number(stats.unique_completers)}
                  <% end %>
                </td>
                <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                  <%= if @completions == %{} do %>
                    <.death_star_spinner class="w-3 h-3 text-gray-300 inline-block" />
                  <% else %>
                    {stats.conversion_rate}%
                  <% end %>
                </td>
                <td class="px-6 py-4 text-right">
                  <button
                    phx-click="delete_goal"
                    phx-value-id={goal.id}
                    data-confirm="Are you sure you want to delete this goal?"
                    class="text-red-600 hover:text-red-800 text-sm"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
