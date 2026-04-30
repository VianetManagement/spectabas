defmodule SpectabasWeb.Dashboard.FunnelDetailLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Goals, Analytics, Visitors}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id, "funnel_id" => funnel_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      funnel = Goals.get_funnel_for_site!(site, funnel_id)

      {:ok,
       socket
       |> assign(:page_title, "#{funnel.name} - Funnels - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:funnel, funnel)
       |> assign(:range, "30d")
       |> assign(:funnel_data, nil)
       |> assign(:timeseries_json, "{}")
       |> assign(:loading, true)
       |> assign(:editing, false)
       |> assign(:edit_name, funnel.name)
       |> assign(:edit_steps, funnel.steps || [])
       |> assign(:goals, Goals.list_goals(site))
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
    funnel = socket.assigns.funnel
    range = socket.assigns.range

    raw_data =
      case Analytics.funnel_stats(site, user, funnel, range) do
        {:ok, data} -> data
        _ -> []
      end

    funnel_data = process_funnel_data(funnel, raw_data, site)

    timeseries =
      case Analytics.funnel_completion_timeseries(site, user, funnel, range) do
        {:ok, rows} -> rows
        _ -> []
      end

    timeseries_json = build_timeseries_json(timeseries)

    {:noreply,
     socket
     |> assign(:funnel_data, funnel_data)
     |> assign(:timeseries_json, timeseries_json)
     |> assign(:loading, false)}
  rescue
    _ ->
      {:noreply, assign(socket, loading: false, funnel_data: [], timeseries_json: "{}")}
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:loading, true)
     |> then(fn s ->
       send(self(), :load_data)
       s
     end)}
  end

  def handle_event("export_abandoned", %{"step" => step_str}, socket) do
    step = String.to_integer(step_str)

    case Analytics.funnel_abandoned_at_step(
           socket.assigns.site,
           socket.assigns.user,
           socket.assigns.funnel,
           step
         ) do
      {:ok, visitor_ids} ->
        email_map = Visitors.emails_for_visitor_ids(visitor_ids)

        csv_rows =
          Enum.map(visitor_ids, fn vid ->
            email = get_in(email_map, [vid, :email]) || ""
            "#{vid},#{email}"
          end)

        csv = "visitor_id,email\n" <> Enum.join(csv_rows, "\n")

        filename =
          "#{socket.assigns.funnel.name |> String.replace(~r/[^a-zA-Z0-9]/, "_")}_abandoned_step_#{step}_#{Date.to_iso8601(Date.utc_today())}.csv"

        {:noreply,
         push_event(socket, "download", %{filename: filename, content: csv, mime: "text/csv"})}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not export abandoned visitors.")}
    end
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing, !socket.assigns.editing)
     |> assign(:edit_name, socket.assigns.funnel.name)
     |> assign(:edit_steps, socket.assigns.funnel.steps || [])}
  end

  def handle_event("edit_form_changed", %{"funnel" => params}, socket) do
    name = params["name"] || socket.assigns.edit_name

    steps =
      (params["steps"] || %{})
      |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
      |> Enum.map(fn {_idx, step} -> step end)

    steps =
      if length(steps) < length(socket.assigns.edit_steps),
        do: steps ++ Enum.drop(socket.assigns.edit_steps, length(steps)),
        else: steps

    {:noreply, assign(socket, edit_name: name, edit_steps: steps)}
  end

  def handle_event("add_edit_step", _params, socket) do
    steps = socket.assigns.edit_steps ++ [%{"type" => "pageview", "value" => ""}]
    {:noreply, assign(socket, :edit_steps, steps)}
  end

  def handle_event("remove_edit_step", %{"index" => index}, socket) do
    steps = List.delete_at(socket.assigns.edit_steps, String.to_integer(index))
    {:noreply, assign(socket, :edit_steps, steps)}
  end

  def handle_event("save_funnel", %{"funnel" => params}, socket) do
    steps =
      (params["steps"] || %{})
      |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
      |> Enum.map(fn {_idx, step} -> step end)

    case Goals.update_funnel(socket.assigns.funnel, %{"name" => params["name"], "steps" => steps}) do
      {:ok, funnel} ->
        {:noreply,
         socket
         |> assign(:funnel, funnel)
         |> assign(:editing, false)
         |> assign(:loading, true)
         |> put_flash(:info, "Funnel updated.")
         |> then(fn s ->
           send(self(), :load_data)
           s
         end)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update funnel.")}
    end
  end

  def handle_event("delete_funnel", _params, socket) do
    case Goals.delete_funnel(socket.assigns.site, socket.assigns.funnel.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Funnel deleted.")
         |> redirect(to: ~p"/dashboard/sites/#{socket.assigns.site.id}/funnels")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete funnel.")}
    end
  end

  defp step_placeholder("pageview"), do: "/path"
  defp step_placeholder("custom_event"), do: "event_name"
  defp step_placeholder(_), do: "/path"

  defp goal_type_label("pageview"), do: "pageview"
  defp goal_type_label("custom_event"), do: "custom event"
  defp goal_type_label("click_element"), do: "click"
  defp goal_type_label(t), do: t

  defp process_funnel_data(funnel, raw_data, _site) do
    steps = funnel.steps || []

    if raw_data == [] or steps == [] do
      []
    else
      row = List.first(raw_data) || %{}
      total = to_num(row["step_1"] || 0)

      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, idx} ->
        visitors = to_num(row["step_#{idx}"] || 0)
        prev_visitors = if idx == 1, do: visitors, else: to_num(row["step_#{idx - 1}"] || 0)
        pct = if total > 0, do: Float.round(visitors / total * 100, 1), else: 0.0
        drop_off = if prev_visitors > 0, do: prev_visitors - visitors, else: 0

        drop_pct =
          if prev_visitors > 0, do: Float.round(drop_off / prev_visitors * 100, 1), else: 0.0

        %{
          "name" => step_label(step),
          "type" => step["type"] || Map.get(step, :type, "pageview"),
          "visitors" => visitors,
          "percentage" => pct,
          "drop_off" => drop_off,
          "drop_off_pct" => drop_pct,
          "step_index" => idx
        }
      end)
    end
  end

  defp step_label(step) do
    type = step["type"] || Map.get(step, :type, "pageview")
    value = step["value"] || Map.get(step, :value, "")

    case type do
      "pageview" ->
        value

      "custom_event" ->
        value

      "goal" ->
        try do
          goal = Goals.get_goal!(String.to_integer(value))
          goal.name
        rescue
          _ -> "Goal ##{value}"
        end

      _ ->
        value
    end
  end

  defp step_type_badge("pageview"), do: {"Pageview", "bg-blue-100 text-blue-700"}
  defp step_type_badge("custom_event"), do: {"Event", "bg-purple-100 text-purple-700"}
  defp step_type_badge("goal"), do: {"Goal", "bg-green-100 text-green-700"}
  defp step_type_badge(_), do: {"Step", "bg-gray-100 text-gray-700"}

  defp build_timeseries_json(rows) do
    Jason.encode!(%{
      labels: Enum.map(rows, & &1["day"]),
      visitors: Enum.map(rows, &Spectabas.TypeHelpers.to_float(&1["completion_rate"])),
      label: "Completion rate",
      color: "#6366f1",
      bg_color: "rgba(99, 102, 241, 0.1)",
      value_suffix: "%",
      metric: "visitors"
    })
  rescue
    _ -> "{}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title={@funnel.name}
      page_description="Funnel detail — step-by-step conversion analysis."
      active="funnels"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <%!-- Header --%>
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/funnels"}
            class="text-sm text-indigo-600 hover:text-indigo-800 mb-2 inline-block"
          >
            &larr; Back to Funnels
          </.link>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-bold text-gray-900">{@funnel.name}</h1>
              <span class="text-sm text-gray-500">{length(@funnel.steps || [])} steps</span>
            </div>
            <div class="flex items-center gap-3">
              <div class="flex gap-1">
                <button
                  :for={r <- ~w(7d 30d 90d)}
                  phx-click="change_range"
                  phx-value-range={r}
                  class={[
                    "px-3 py-1.5 text-sm font-medium rounded-lg",
                    if(@range == r,
                      do: "bg-indigo-600 text-white",
                      else: "text-gray-600 hover:bg-gray-100"
                    )
                  ]}
                >
                  {r}
                </button>
              </div>
              <button
                phx-click="toggle_edit"
                class="px-3 py-1.5 text-sm font-medium rounded-lg border border-gray-300 text-gray-600 hover:bg-gray-100"
              >
                {if @editing, do: "Cancel", else: "Edit"}
              </button>
              <button
                phx-click="delete_funnel"
                data-confirm="Delete this funnel?"
                class="px-3 py-1.5 text-sm font-medium rounded-lg text-red-600 hover:bg-red-50"
              >
                Delete
              </button>
            </div>
          </div>
        </div>

        <%!-- Edit Form --%>
        <div :if={@editing} class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Edit Funnel</h2>
          <form
            phx-change="edit_form_changed"
            phx-submit="save_funnel"
            id="edit-funnel-form"
            class="space-y-4"
          >
            <div>
              <label class="block text-sm font-medium text-gray-700">Funnel Name</label>
              <input
                type="text"
                name="funnel[name]"
                value={@edit_name}
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                required
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Steps</label>
              <div class="space-y-3">
                <div
                  :for={{step, idx} <- Enum.with_index(@edit_steps)}
                  class="flex flex-col sm:flex-row sm:items-center gap-2 sm:gap-3"
                >
                  <span class="text-sm font-medium text-gray-500 w-6">{idx + 1}.</span>
                  <% step_type = step["type"] || Map.get(step, :type, "pageview") %>
                  <select
                    name={"funnel[steps][#{idx}][type]"}
                    class="shrink-0 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  >
                    <option value="pageview" selected={step_type == "pageview"}>Pageview</option>
                    <option value="custom_event" selected={step_type == "custom_event"}>
                      Custom Event
                    </option>
                    <option value="goal" selected={step_type == "goal"}>Goal</option>
                  </select>
                  <select
                    :if={step_type == "goal"}
                    name={"funnel[steps][#{idx}][value]"}
                    class="flex-1 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  >
                    <option value="">Select a goal...</option>
                    <option
                      :for={g <- @goals}
                      value={to_string(g.id)}
                      selected={
                        to_string(g.id) == to_string(step["value"] || Map.get(step, :value, ""))
                      }
                    >
                      {g.name} ({goal_type_label(g.goal_type)})
                    </option>
                  </select>
                  <input
                    :if={step_type in ["pageview", "custom_event"]}
                    type="text"
                    name={"funnel[steps][#{idx}][value]"}
                    value={step["value"] || Map.get(step, :value, "")}
                    placeholder={step_placeholder(step_type)}
                    class="flex-1 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                  <button
                    :if={length(@edit_steps) > 1}
                    type="button"
                    phx-click="remove_edit_step"
                    phx-value-index={idx}
                    class="text-red-500 hover:text-red-700 text-sm"
                  >
                    Remove
                  </button>
                </div>
              </div>
              <button
                type="button"
                phx-click="add_edit_step"
                class="mt-3 text-sm text-indigo-600 hover:text-indigo-800"
              >
                + Add step
              </button>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-lg shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Save Changes
              </button>
            </div>
          </form>
        </div>

        <div :if={@loading} class="flex items-center justify-center py-16 gap-2 text-gray-400">
          <.death_star_spinner class="w-6 h-6" />
          <span class="text-sm">Loading...</span>
        </div>

        <div :if={!@loading}>
          <%!-- Summary Cards --%>
          <div
            :if={@funnel_data != []}
            class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4 mb-8"
          >
            <% first_step = List.first(@funnel_data) || %{}
            last_step = List.last(@funnel_data) || %{}
            entered = first_step["visitors"] || 0
            completed = last_step["visitors"] || 0
            completion_rate = if entered > 0, do: Float.round(completed / entered * 100, 1), else: 0.0
            total_drop = entered - completed %>
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Entered</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">{format_number(entered)}</p>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Completed</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">{format_number(completed)}</p>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Completion Rate</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">{completion_rate}%</p>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <p class="text-sm text-gray-500">Total Drop-off</p>
              <p class="text-2xl font-bold text-gray-900 mt-1">{format_number(total_drop)}</p>
            </div>
          </div>

          <%!-- Completion Rate Trend --%>
          <div :if={@funnel_data != []} class="bg-white rounded-lg shadow p-5 mb-8">
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-sm font-semibold text-gray-700">Completion Rate Over Time</h2>
              <span class="text-xs text-gray-400">
                % of entrants who completed all steps, by entry day
              </span>
            </div>
            <div
              id={"funnel-rate-chart-#{@funnel.id}-#{@range}"}
              phx-hook="TimeseriesChart"
              phx-update="ignore"
              data-chart={@timeseries_json}
              class="h-48 sm:h-[240px] relative"
            >
              <canvas></canvas>
            </div>
          </div>

          <%!-- Funnel Visualization --%>
          <div class="bg-white rounded-lg shadow p-6 mb-8">
            <h2 class="text-sm font-semibold text-gray-700 mb-4">Conversion Funnel</h2>
            <div :if={@funnel_data == []} class="text-center py-8 text-gray-400">
              No data for this period.
            </div>
            <div :if={@funnel_data != []} class="space-y-4">
              <div :for={step <- @funnel_data} class="relative">
                <div class="flex items-center gap-4">
                  <span class="text-sm font-medium text-gray-400 w-6 text-right">
                    {step["step_index"]}
                  </span>
                  <div class="flex-1">
                    <div class="flex items-center justify-between mb-1.5">
                      <div class="flex items-center gap-2">
                        <% {type_label, type_class} = step_type_badge(step["type"]) %>
                        <span class={["px-1.5 py-0.5 rounded text-[10px] font-medium", type_class]}>
                          {type_label}
                        </span>
                        <span class="text-sm font-medium text-gray-900">{step["name"]}</span>
                      </div>
                      <div class="flex items-center gap-4">
                        <span class="text-sm font-bold text-gray-900 tabular-nums">
                          {format_number(step["visitors"])}
                        </span>
                        <span class="text-sm text-gray-500 tabular-nums w-14 text-right">
                          {step["percentage"]}%
                        </span>
                      </div>
                    </div>
                    <div class="w-full bg-gray-100 rounded-full h-3">
                      <div
                        class="bg-indigo-500 h-3 rounded-full transition-all duration-500"
                        style={"width: #{step["percentage"]}%"}
                      >
                      </div>
                    </div>
                  </div>
                </div>
                <%!-- Drop-off indicator between steps --%>
                <div
                  :if={step["drop_off"] > 0}
                  class="ml-10 mt-1 flex items-center gap-2 text-xs text-red-500"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="w-3 h-3"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M19 14l-7 7m0 0l-7-7m7 7V3"
                    />
                  </svg>
                  {format_number(step["drop_off"])} dropped ({step["drop_off_pct"]}%)
                  <button
                    phx-click="export_abandoned"
                    phx-value-step={step["step_index"]}
                    class="ml-1 text-indigo-600 hover:text-indigo-800 underline"
                  >
                    Export CSV
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Step Details Table --%>
          <div :if={@funnel_data != []} class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-200">
              <h2 class="text-sm font-semibold text-gray-700">Step Breakdown</h2>
            </div>
            <div class="overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Step
                    </th>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Type
                    </th>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Target
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      % of Entry
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Drop-off
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Drop %
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :for={step <- @funnel_data} class="hover:bg-gray-50">
                    <td class="px-5 py-3 text-sm font-medium text-gray-900">{step["step_index"]}</td>
                    <td class="px-5 py-3">
                      <% {type_label, type_class} = step_type_badge(step["type"]) %>
                      <span class={["px-1.5 py-0.5 rounded text-xs font-medium", type_class]}>
                        {type_label}
                      </span>
                    </td>
                    <td class="px-5 py-3 text-sm text-gray-700 font-mono">{step["name"]}</td>
                    <td class="px-5 py-3 text-sm text-gray-900 text-right tabular-nums font-semibold">
                      {format_number(step["visitors"])}
                    </td>
                    <td class="px-5 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {step["percentage"]}%
                    </td>
                    <td class={[
                      "px-5 py-3 text-sm text-right tabular-nums",
                      if(step["drop_off"] > 0, do: "text-red-600", else: "text-gray-400")
                    ]}>
                      {if step["drop_off"] > 0, do: format_number(step["drop_off"]), else: "—"}
                    </td>
                    <td class={[
                      "px-5 py-3 text-sm text-right tabular-nums",
                      if(step["drop_off_pct"] > 0, do: "text-red-600", else: "text-gray-400")
                    ]}>
                      {if step["drop_off_pct"] > 0, do: "#{step["drop_off_pct"]}%", else: "—"}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
