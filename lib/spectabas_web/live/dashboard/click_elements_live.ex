defmodule SpectabasWeb.Dashboard.ClickElementsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Goals, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Click Elements - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:elements, [])
       |> assign(:element_names, %{})
       |> assign(:goals, [])
       |> assign(:funnels, [])
       |> assign(:tag_filter, nil)
       |> assign(:sort_by, "clicks")
       |> assign(:sort_dir, "DESC")
       |> assign(:editing_key, nil)
       |> assign(:edit_name, "")
       |> assign(:loading, true)
       |> then(fn s ->
         send(self(), :load_data)
         s
       end)}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    site = socket.assigns.site
    user = socket.assigns.user

    elements =
      safe_query(fn ->
        Analytics.discovered_click_elements_full(site, user,
          tag_filter: socket.assigns.tag_filter,
          sort_by: socket.assigns.sort_by,
          sort_dir: socket.assigns.sort_dir
        )
      end)

    names = Goals.element_names_map(site)
    goals = Goals.list_goals(site)
    funnels = Goals.list_funnels(site)

    {:noreply,
     socket
     |> assign(:elements, elements)
     |> assign(:element_names, names)
     |> assign(:goals, goals)
     |> assign(:funnels, funnels)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    tag = if tag == "", do: nil, else: tag

    {:noreply,
     socket
     |> assign(:tag_filter, tag)
     |> assign(:loading, true)
     |> then(fn s ->
       send(self(), :load_data)
       s
     end)}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    dir =
      if socket.assigns.sort_by == col and socket.assigns.sort_dir == "DESC",
        do: "ASC",
        else: "DESC"

    {:noreply,
     socket
     |> assign(:sort_by, col)
     |> assign(:sort_dir, dir)
     |> assign(:loading, true)
     |> then(fn s ->
       send(self(), :load_data)
       s
     end)}
  end

  def handle_event("edit_name", %{"key" => key}, socket) do
    current = Map.get(socket.assigns.element_names, key)
    name = if current, do: current.friendly_name, else: ""
    {:noreply, assign(socket, editing_key: key, edit_name: name)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_key: nil)}
  end

  def handle_event("save_name", %{"key" => key, "name" => name}, socket) do
    name = String.trim(name)

    if name != "" do
      Goals.upsert_element_name(socket.assigns.site, %{
        "element_key" => key,
        "friendly_name" => name
      })
    end

    names = Goals.element_names_map(socket.assigns.site)

    {:noreply,
     socket
     |> assign(:element_names, names)
     |> assign(:editing_key, nil)
     |> put_flash(:info, "Name saved.")}
  end

  def handle_event("toggle_ignore", %{"key" => key}, socket) do
    Goals.ignore_element(socket.assigns.site, key)
    names = Goals.element_names_map(socket.assigns.site)
    {:noreply, assign(socket, :element_names, names)}
  end

  def handle_event("create_goal", %{"key" => key, "name" => name}, socket) do
    case Goals.create_goal(socket.assigns.site, %{
           "name" => "Click: #{name}" |> String.slice(0..99),
           "goal_type" => "click_element",
           "element_selector" => key
         }) do
      {:ok, _} ->
        goals = Goals.list_goals(socket.assigns.site)
        {:noreply, socket |> put_flash(:info, "Goal created.") |> assign(:goals, goals)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create goal.")}
    end
  end

  defp element_key(el) do
    id = to_string(el["element_id"])
    if id != "", do: "##{id}", else: "text:#{el["element_text"]}"
  end

  defp element_display_name(el, names) do
    key = element_key(el)
    name_rec = Map.get(names, key)
    if name_rec, do: name_rec.friendly_name, else: nil
  end

  defp element_is_ignored?(el, names) do
    key = element_key(el)

    case Map.get(names, key) do
      %{ignored: true} -> true
      _ -> false
    end
  end

  defp goals_for_element(el, goals) do
    key = element_key(el)
    Enum.filter(goals, &(&1.goal_type == "click_element" and &1.element_selector == key))
  end

  defp tag_classes(tag) do
    case to_string(tag) |> String.downcase() do
      "a" -> "bg-blue-100 text-blue-700"
      "button" -> "bg-green-100 text-green-700"
      "input" -> "bg-amber-100 text-amber-700"
      _ -> "bg-gray-100 text-gray-700"
    end
  end

  defp sort_indicator(col, sort_by, sort_dir) do
    if col == sort_by, do: if(sort_dir == "ASC", do: " ↑", else: " ↓"), else: ""
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Click Elements"
      page_description="Auto-detected buttons and links from your site. Assign names and create goals."
      active="click-elements"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Click Elements</h1>
          <div class="flex items-center gap-3">
            <select
              phx-change="filter_tag"
              name="tag"
              class="rounded-lg border-gray-300 text-sm focus:border-indigo-500 focus:ring-indigo-500"
            >
              <option value="" selected={is_nil(@tag_filter)}>All tags</option>
              <option value="button" selected={@tag_filter == "button"}>Buttons</option>
              <option value="a" selected={@tag_filter == "a"}>Links</option>
              <option value="input" selected={@tag_filter == "input"}>Inputs</option>
            </select>
          </div>
        </div>

        <div :if={@loading} class="text-center py-16 text-gray-400">Loading...</div>

        <div :if={!@loading && @elements == []} class="bg-white rounded-lg shadow p-8 text-center">
          <p class="text-gray-500 mb-2 font-medium">No click elements detected yet</p>
          <p class="text-sm text-gray-400">
            Buttons and links on your site will appear here automatically once visitors start clicking them. This typically takes a few hours after the tracker is deployed.
          </p>
        </div>

        <div :if={!@loading && @elements != []} class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Tag</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Element
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Name</th>
                <th
                  class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer"
                  phx-click="sort"
                  phx-value-col="clicks"
                >
                  Clicks{sort_indicator("clicks", @sort_by, @sort_dir)}
                </th>
                <th
                  class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer"
                  phx-click="sort"
                  phx-value-col="visitors"
                >
                  Visitors{sort_indicator("visitors", @sort_by, @sort_dir)}
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Pages</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Goals</th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200">
              <tr
                :for={el <- @elements}
                :if={!element_is_ignored?(el, @element_names)}
                class="hover:bg-gray-50"
              >
                <td class="px-4 py-3">
                  <span class={[
                    "px-1.5 py-0.5 rounded text-xs font-mono",
                    tag_classes(el["element_tag"])
                  ]}>
                    {el["element_tag"]}
                  </span>
                </td>
                <td class="px-4 py-3 max-w-[200px]">
                  <div class="text-sm font-medium text-gray-900 truncate">
                    {el["element_text"] |> to_string() |> String.slice(0..59)}
                  </div>
                  <div :if={to_string(el["element_id"]) != ""} class="text-xs text-gray-400 font-mono">
                    #{el["element_id"]}
                  </div>
                </td>
                <td class="px-4 py-3">
                  <div :if={@editing_key == element_key(el)}>
                    <form phx-submit="save_name" class="flex gap-1">
                      <input type="hidden" name="key" value={element_key(el)} />
                      <input
                        type="text"
                        name="name"
                        value={@edit_name}
                        class="text-sm rounded-lg border-gray-300 px-2 py-1 w-36 focus:border-indigo-500 focus:ring-indigo-500"
                        autofocus
                      />
                      <button type="submit" class="text-xs text-indigo-600 hover:text-indigo-800">
                        Save
                      </button>
                      <button
                        type="button"
                        phx-click="cancel_edit"
                        class="text-xs text-gray-400 hover:text-gray-600"
                      >
                        Cancel
                      </button>
                    </form>
                  </div>
                  <div :if={@editing_key != element_key(el)}>
                    <button
                      phx-click="edit_name"
                      phx-value-key={element_key(el)}
                      class="text-sm text-gray-600 hover:text-indigo-600"
                    >
                      {element_display_name(el, @element_names) || "—"}
                    </button>
                  </div>
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums font-semibold">
                  {format_number(to_num(el["clicks"]))}
                </td>
                <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                  {format_number(to_num(el["visitors"]))}
                </td>
                <td class="px-4 py-3">
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={page <- (el["sample_pages"] || []) |> Enum.take(3)}
                      class="inline-flex px-1.5 py-0.5 rounded bg-gray-100 text-[10px] font-mono text-gray-500 truncate max-w-[100px]"
                    >
                      {page}
                    </span>
                  </div>
                </td>
                <td class="px-4 py-3">
                  <div class="flex flex-wrap gap-1">
                    <.link
                      :for={g <- goals_for_element(el, @goals)}
                      navigate={~p"/dashboard/sites/#{@site.id}/goals/#{g.id}"}
                      class="inline-flex px-1.5 py-0.5 rounded bg-green-100 text-green-700 text-[10px] font-medium hover:bg-green-200"
                    >
                      {g.name}
                    </.link>
                  </div>
                </td>
                <td class="px-4 py-3 text-right">
                  <div class="flex items-center justify-end gap-2">
                    <button
                      :if={goals_for_element(el, @goals) == []}
                      phx-click="create_goal"
                      phx-value-key={element_key(el)}
                      phx-value-name={el["element_text"] |> to_string() |> String.slice(0..39)}
                      class="text-xs text-indigo-600 hover:text-indigo-800"
                    >
                      Create Goal
                    </button>
                    <button
                      phx-click="toggle_ignore"
                      phx-value-key={element_key(el)}
                      class="text-xs text-gray-400 hover:text-gray-600"
                    >
                      Hide
                    </button>
                  </div>
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
