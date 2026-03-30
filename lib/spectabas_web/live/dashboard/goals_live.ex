defmodule SpectabasWeb.Dashboard.GoalsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Goal tracking — pageview and custom event goal completions."

  alias Spectabas.{Accounts, Sites, Goals, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      goals = Goals.list_goals(site)

      completions =
        case Analytics.goal_completions(site, user, :week) do
          {:ok, data} -> data
          _ -> %{}
        end

      {:ok,
       socket
       |> assign(:page_title, "Goals - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:goals, goals)
       |> assign(:completions, completions)
       |> assign(:show_form, false)
       |> assign(:form, to_form(goal_changeset()))
       |> assign(:goal_type, "pageview")}
    end
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  def handle_event("change_goal_type", %{"goal_type" => type}, socket) do
    {:noreply, assign(socket, :goal_type, type)}
  end

  def handle_event("create_goal", %{"goal" => params}, socket) do
    case Goals.create_goal(socket.assigns.site, params) do
      {:ok, _goal} ->
        goals = Goals.list_goals(socket.assigns.site)

        {:noreply,
         socket
         |> put_flash(:info, "Goal created.")
         |> assign(:goals, goals)
         |> assign(:show_form, false)
         |> assign(:form, to_form(goal_changeset()))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("validate_goal", %{"goal" => params}, socket) do
    changeset =
      %Goals.Goal{}
      |> Goals.Goal.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("delete_goal", %{"id" => id}, socket) do
    goal = Goals.get_goal!(id)

    case Goals.delete_goal(goal, socket.assigns.user) do
      {:ok, _} ->
        goals = Goals.list_goals(socket.assigns.site)
        {:noreply, socket |> put_flash(:info, "Goal deleted.") |> assign(:goals, goals)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete goal.")}
    end
  end

  defp goal_changeset do
    Goals.Goal.changeset(%Goals.Goal{}, %{})
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
        <div class="flex items-center justify-between mb-8">
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
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                required
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Goal Type</label>
              <div class="flex gap-4">
                <label :for={t <- ["pageview", "custom_event"]} class="flex items-center gap-2">
                  <input
                    type="radio"
                    name="goal[goal_type]"
                    value={t}
                    checked={@goal_type == t}
                    phx-click="change_goal_type"
                    phx-value-goal_type={t}
                    class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300"
                  />
                  <span class="text-sm text-gray-700">
                    {String.replace(t, "_", " ") |> String.capitalize()}
                  </span>
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
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
            </div>
            <div :if={@goal_type == "custom_event"}>
              <label class="block text-sm font-medium text-gray-700">Event Name</label>
              <input
                type="text"
                name="goal[event_name]"
                value={@form[:event_name].value}
                placeholder="signup_complete"
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
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
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Name
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Type
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Target
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Completions (7d)
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@goals == []}>
                <td colspan="5" class="px-6 py-8 text-center text-gray-500">No goals configured.</td>
              </tr>
              <tr :for={goal <- @goals} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-medium text-gray-900">{goal.name}</td>
                <td class="px-6 py-4">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    if(goal.goal_type == "pageview",
                      do: "bg-blue-100 text-blue-800",
                      else: "bg-purple-100 text-purple-800"
                    )
                  ]}>
                    {goal.goal_type}
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500 font-mono">
                  {goal.page_path || goal.event_name || "-"}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right font-semibold">
                  {Map.get(@completions, goal.id, 0)}
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
