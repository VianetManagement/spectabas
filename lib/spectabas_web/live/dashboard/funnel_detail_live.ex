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
    funnel = socket.assigns.funnel
    range = socket.assigns.range

    raw_data =
      case Analytics.funnel_stats(site, user, funnel, range) do
        {:ok, data} -> data
        _ -> []
      end

    funnel_data = process_funnel_data(funnel, raw_data, site)

    {:noreply,
     socket
     |> assign(:funnel_data, funnel_data)
     |> assign(:loading, false)}
  rescue
    _ -> {:noreply, assign(socket, loading: false, funnel_data: [])}
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
          </div>
        </div>

        <div :if={@loading} class="text-center py-16 text-gray-400">Loading...</div>

        <div :if={!@loading}>
          <%!-- Summary Cards --%>
          <div :if={@funnel_data != []} class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
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
