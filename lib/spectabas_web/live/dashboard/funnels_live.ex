defmodule SpectabasWeb.Dashboard.FunnelsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Conversion funnels — multi-step visitor flow analysis."

  alias Spectabas.{Accounts, Sites, Goals, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

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
      funnels = Goals.list_funnels(site)

      {:ok,
       socket
       |> assign(:page_title, "Funnels - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:funnels, funnels)
       |> assign(:selected_funnel, nil)
       |> assign(:funnel_data, nil)
       |> assign(:show_form, false)
       |> assign(:form_name, "")
       |> assign(:form_steps, [%{name: "", type: "pageview", value: ""}])
       |> assign(:discovered_elements, [])
       |> assign(:goals, Goals.list_goals(site))
       |> assign(:suggestions, nil)
       |> assign(:suggestions_loading, true)
       |> then(fn s ->
         send(self(), :load_suggestions)
         s
       end)}
    end
  end

  @impl true
  def handle_info(:load_suggestions, socket) do
    suggestions =
      safe_query(fn -> Analytics.suggested_funnels(socket.assigns.site, socket.assigns.user) end)

    {:noreply, assign(socket, suggestions: suggestions, suggestions_loading: false)}
  rescue
    _ -> {:noreply, assign(socket, suggestions: [], suggestions_loading: false)}
  end

  @impl true
  def handle_event("create_suggested", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    suggestion = Enum.at(socket.assigns.suggestions || [], idx)

    if suggestion do
      paths = suggestion["path_sequence"]
      # path_sequence comes back as a ClickHouse Array(String)
      paths = if is_list(paths), do: paths, else: []

      steps = Enum.map(paths, fn path -> %{"type" => "pageview", "value" => path} end)
      name = paths |> Enum.map(&String.trim_leading(&1, "/")) |> Enum.join(" → ")

      case Goals.create_funnel(socket.assigns.site, %{"name" => name, "steps" => steps}) do
        {:ok, _funnel} ->
          funnels = Goals.list_funnels(socket.assigns.site)

          {:noreply,
           socket
           |> put_flash(:info, "Funnel created from suggestion.")
           |> assign(:funnels, funnels)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create funnel.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_form", _params, socket) do
    if socket.assigns.show_form do
      {:noreply, assign(socket, :show_form, false)}
    else
      elements =
        safe_query(fn ->
          Analytics.discovered_click_elements(socket.assigns.site, socket.assigns.user)
        end)

      {:noreply,
       socket
       |> assign(:show_form, true)
       |> assign(:goals, Goals.list_goals(socket.assigns.site))
       |> assign(:discovered_elements, elements)}
    end
  end

  def handle_event("set_step_value", %{"index" => index, "value" => value}, socket) do
    idx = String.to_integer(index)
    steps = List.update_at(socket.assigns.form_steps, idx, &Map.put(&1, "value", value))
    {:noreply, assign(socket, :form_steps, steps)}
  end

  def handle_event("add_step", _params, socket) do
    steps = socket.assigns.form_steps ++ [%{name: "", type: "pageview", value: ""}]
    {:noreply, assign(socket, :form_steps, steps)}
  end

  def handle_event("remove_step", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    steps = List.delete_at(socket.assigns.form_steps, idx)
    {:noreply, assign(socket, :form_steps, steps)}
  end

  def handle_event("form_changed", %{"funnel" => params}, socket) do
    name = params["name"] || socket.assigns.form_name
    steps_params = params["steps"] || %{}

    # Rebuild steps from form params, preserving order
    steps =
      steps_params
      |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
      |> Enum.map(fn {_idx, step} -> step end)

    # Pad with existing steps if new steps were added via add_step but not yet in form data
    steps =
      if length(steps) < length(socket.assigns.form_steps) do
        steps ++ Enum.drop(socket.assigns.form_steps, length(steps))
      else
        steps
      end

    {:noreply, assign(socket, form_name: name, form_steps: steps)}
  end

  def handle_event("create_funnel", %{"funnel" => params}, socket) do
    if !Accounts.can_write?(socket.assigns.current_scope.user) do
      {:noreply, put_flash(socket, :error, "Viewers have read-only access.")}
    else
      steps =
        (params["steps"] || %{})
        |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
        |> Enum.map(fn {_idx, step} -> step end)

      funnel_params = %{"name" => params["name"], "steps" => steps}

      case Goals.create_funnel(socket.assigns.site, funnel_params) do
        {:ok, _funnel} ->
          funnels = Goals.list_funnels(socket.assigns.site)

          {:noreply,
           socket
           |> put_flash(:info, "Funnel created.")
           |> assign(:funnels, funnels)
           |> assign(:show_form, false)
           |> assign(:form_name, "")
           |> assign(:form_steps, [%{name: "", type: "pageview", value: ""}])}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to create funnel.")}
      end
    end
  end

  def handle_event("view_funnel", %{"id" => id}, socket) do
    funnel = Enum.find(socket.assigns.funnels, &(to_string(&1.id) == id))

    funnel_data =
      case Analytics.funnel_stats(socket.assigns.site, socket.assigns.user, funnel) do
        {:ok, data} -> data
        _ -> []
      end

    # Enrich funnel with revenue data if ecommerce enabled
    funnel_data =
      if socket.assigns.site.ecommerce_enabled do
        enrich_funnel_with_revenue(socket.assigns.site, funnel_data)
      else
        funnel_data
      end

    {:noreply,
     socket
     |> assign(:selected_funnel, funnel)
     |> assign(:funnel_data, funnel_data)}
  end

  def handle_event("export_abandoned", %{"step" => step_str}, socket) do
    step = String.to_integer(step_str)
    funnel = socket.assigns.selected_funnel
    site = socket.assigns.site

    # Get visitor IDs who reached this step but not the next
    case Analytics.funnel_abandoned_at_step(site, socket.assigns.user, funnel, step) do
      {:ok, visitor_ids} ->
        email_map = Spectabas.Visitors.emails_for_visitor_ids(visitor_ids)

        csv_rows =
          Enum.map(visitor_ids, fn vid ->
            email = get_in(email_map, [vid, :email]) || ""
            "#{vid},#{email}"
          end)

        csv = "visitor_id,email\n" <> Enum.join(csv_rows, "\n")
        filename = "abandoned_step_#{step}_#{Date.to_iso8601(Date.utc_today())}.csv"

        {:noreply,
         socket
         |> push_event("download", %{filename: filename, content: csv, mime: "text/csv"})}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not export abandoned visitors.")}
    end
  end

  def handle_event("close_funnel", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_funnel, nil)
     |> assign(:funnel_data, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Funnels"
      page_description="Conversion funnels showing drop-off at each step."
      active="funnels"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Funnels</h1>
          </div>
          <button
            phx-click="toggle_form"
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
          >
            {if @show_form, do: "Cancel", else: "New Funnel"}
          </button>
        </div>

        <%!-- Create Form --%>
        <div :if={@show_form} class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Create Funnel</h2>
          <form
            phx-change="form_changed"
            phx-submit="create_funnel"
            class="space-y-4"
            id="funnel-form"
          >
            <div>
              <label class="block text-sm font-medium text-gray-700">Funnel Name</label>
              <input
                type="text"
                name="funnel[name]"
                value={@form_name}
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                required
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-2">Steps</label>
              <div class="space-y-3">
                <div
                  :for={{step, idx} <- Enum.with_index(@form_steps)}
                  class="flex items-center gap-3"
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
                    <option value="click_element" selected={step_type == "click_element"}>
                      Click Element
                    </option>
                    <option value="goal" selected={step_type == "goal"}>Goal</option>
                  </select>
                  <%!-- Goal selector --%>
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
                  <%!-- Click element: text input + filtered suggestions --%>
                  <div :if={step_type == "click_element"} class="flex-1 relative">
                    <% step_val = step["value"] || Map.get(step, :value, "") %>
                    <input
                      type="text"
                      name={"funnel[steps][#{idx}][value]"}
                      value={step_val}
                      placeholder="Search elements or type #id / text:..."
                      autocomplete="off"
                      class="w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                    />
                    <% matches = filter_elements(@discovered_elements, step_val) %>
                    <div
                      :if={matches != [] && step_val == ""}
                      class="mt-1 border border-gray-200 rounded-lg bg-white shadow-sm max-h-36 overflow-y-auto"
                    >
                      <button
                        :for={el <- Enum.take(matches, 5)}
                        type="button"
                        phx-click="set_step_value"
                        phx-value-index={idx}
                        phx-value-value={element_selector(el)}
                        class="w-full text-left px-3 py-1.5 text-xs hover:bg-indigo-50 flex items-center justify-between gap-2 border-b border-gray-100 last:border-0"
                      >
                        <span class="flex items-center gap-1.5 truncate">
                          <span class={[
                            "px-1 py-0.5 rounded font-mono text-[10px]",
                            element_tag_classes(el["element_tag"])
                          ]}>
                            {el["element_tag"]}
                          </span>
                          <span class="truncate">
                            {el["element_text"] |> to_string() |> String.slice(0..39)}
                          </span>
                        </span>
                        <span class="text-gray-400 shrink-0">
                          {format_number(to_num(el["clicks"]))}
                        </span>
                      </button>
                    </div>
                  </div>
                  <%!-- Text input for pageview/custom_event --%>
                  <input
                    :if={step_type in ["pageview", "custom_event"]}
                    type="text"
                    name={"funnel[steps][#{idx}][value]"}
                    value={step["value"] || Map.get(step, :value, "")}
                    placeholder={step_placeholder(step)}
                    class="flex-1 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                  <button
                    :if={length(@form_steps) > 1}
                    type="button"
                    phx-click="remove_step"
                    phx-value-index={idx}
                    class="text-red-500 hover:text-red-700 text-sm"
                  >
                    Remove
                  </button>
                </div>
              </div>
              <button
                type="button"
                phx-click="add_step"
                class="mt-3 text-sm text-indigo-600 hover:text-indigo-800"
              >
                + Add step
              </button>
              <p class="mt-2 text-xs text-gray-400">
                Tip: Use Click Element to search detected buttons/links, or use Goal to reference an existing goal.
              </p>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-lg shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Create Funnel
              </button>
            </div>
          </form>
        </div>

        <%!-- Funnel Visualization --%>
        <div :if={@selected_funnel} class="bg-white rounded-lg shadow p-6 mb-8">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold text-gray-900">{@selected_funnel.name}</h2>
            <button phx-click="close_funnel" class="text-sm text-gray-500 hover:text-gray-700">
              Close
            </button>
          </div>
          <div :if={@funnel_data} class="space-y-3">
            <div
              :for={{step, idx} <- Enum.with_index(@funnel_data || [])}
              class="flex items-center gap-4"
            >
              <span class="text-sm font-medium text-gray-500 w-6">{idx + 1}</span>
              <div class="flex-1">
                <div class="flex items-center justify-between mb-1">
                  <span class="text-sm text-gray-900">
                    {Map.get(step, "name", "Step #{idx + 1}")}
                  </span>
                  <div class="flex items-center gap-3">
                    <span
                      :if={step["revenue"]}
                      class="text-xs font-medium text-green-600"
                      title="Revenue from visitors who reached this step"
                    >
                      {Spectabas.Currency.format(step["revenue"], @site.currency)}
                    </span>
                    <span class="text-sm font-medium text-gray-900">
                      {format_number(to_num(Map.get(step, "visitors", 0)))}
                    </span>
                  </div>
                </div>
                <div class="w-full bg-gray-200 rounded-full h-2">
                  <div
                    class="bg-indigo-600 h-2 rounded-full"
                    style={"width: #{Map.get(step, "percentage", 0)}%"}
                  >
                  </div>
                </div>
              </div>
              <span class="text-sm text-gray-500 w-12 text-right">
                {Map.get(step, "percentage", 0)}%
              </span>
              <button
                :if={idx < length(@funnel_data) - 1}
                phx-click="export_abandoned"
                phx-value-step={idx + 1}
                class="text-xs text-indigo-600 hover:text-indigo-800 whitespace-nowrap"
                title="Export visitors who dropped off at this step"
              >
                Export drop-off
              </button>
            </div>
          </div>
          <p :if={!@funnel_data || @funnel_data == []} class="text-sm text-gray-500">
            No funnel data available.
          </p>
        </div>

        <%!-- Suggested Funnels --%>
        <div :if={@suggestions && @suggestions != []} class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-sm font-semibold text-gray-700 mb-3">Suggested Funnels</h2>
          <p class="text-xs text-gray-400 mb-4">
            Common page paths taken by converting visitors in the last 30 days.
          </p>
          <div class="space-y-2">
            <div
              :for={{suggestion, idx} <- Enum.with_index(@suggestions)}
              class="flex items-center justify-between p-3 rounded-lg border border-gray-200 hover:border-indigo-200 hover:bg-indigo-50/50 transition-colors"
            >
              <div class="flex items-center gap-2 min-w-0 flex-1">
                <div class="flex items-center gap-1 flex-wrap">
                  <span
                    :for={{path, pidx} <- Enum.with_index(suggestion["path_sequence"] || [])}
                    class="flex items-center gap-1"
                  >
                    <span :if={pidx > 0} class="text-gray-300 text-xs">→</span>
                    <span class="inline-flex px-2 py-0.5 rounded bg-gray-100 text-xs font-mono text-gray-700 truncate max-w-[140px]">
                      {path}
                    </span>
                  </span>
                </div>
              </div>
              <div class="flex items-center gap-3 shrink-0 ml-3">
                <span class="text-xs text-gray-500 tabular-nums">
                  {format_number(to_num(suggestion["converters"]))} converters
                </span>
                <button
                  phx-click="create_suggested"
                  phx-value-index={idx}
                  class="inline-flex items-center px-2.5 py-1 text-xs font-medium rounded-lg text-indigo-600 border border-indigo-300 hover:bg-indigo-600 hover:text-white transition-colors"
                >
                  Create
                </button>
              </div>
            </div>
          </div>
        </div>
        <div :if={@suggestions_loading} class="bg-white rounded-lg shadow p-6 mb-8">
          <p class="text-sm text-gray-400">Analyzing conversion paths...</p>
        </div>

        <%!-- Funnel List --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Name
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Steps
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Status
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@funnels == []}>
                <td colspan="3" class="px-6 py-8 text-center text-gray-500">
                  No funnels configured.
                </td>
              </tr>
              <tr :for={funnel <- @funnels} class="hover:bg-gray-50">
                <td class="px-6 py-4">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/funnels/#{funnel.id}"}
                    class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
                  >
                    {funnel.name}
                  </.link>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">{length(funnel.steps || [])} steps</td>
                <td class="px-6 py-4">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    if(funnel.active,
                      do: "bg-green-100 text-green-800",
                      else: "bg-gray-100 text-gray-800"
                    )
                  ]}>
                    {if funnel.active, do: "Active", else: "Inactive"}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp enrich_funnel_with_revenue(site, funnel_data) do
    # Get all visitor IDs from each step level and check their revenue
    Enum.map(funnel_data, fn step ->
      visitor_ids = Map.get(step, "visitor_ids", [])

      if visitor_ids != [] do
        case Analytics.ecommerce_for_visitors(site, visitor_ids) do
          {:ok, ecom_map} ->
            total_revenue =
              ecom_map
              |> Map.values()
              |> Enum.reduce(0, fn %{revenue: r}, acc ->
                acc + parse_revenue(r)
              end)

            Map.put(step, "revenue", format_money(total_revenue))

          _ ->
            step
        end
      else
        step
      end
    end)
  end

  defp filter_elements(elements, query) when is_list(elements) do
    if query == "" or is_nil(query) do
      elements
    else
      q = String.downcase(to_string(query))

      Enum.filter(elements, fn el ->
        text = to_string(el["element_text"]) |> String.downcase()
        id = to_string(el["element_id"]) |> String.downcase()
        String.contains?(text, q) or String.contains?(id, q)
      end)
    end
  end

  defp filter_elements(_, _), do: []

  defp element_selector(el) do
    id = to_string(el["element_id"])
    if id != "", do: "##{id}", else: "text:#{el["element_text"]}"
  end

  defp element_tag_classes(tag) do
    case to_string(tag) |> String.downcase() do
      "a" -> "bg-blue-100 text-blue-700"
      "button" -> "bg-green-100 text-green-700"
      "input" -> "bg-amber-100 text-amber-700"
      _ -> "bg-gray-100 text-gray-700"
    end
  end

  defp step_placeholder(step) do
    case Map.get(step, :type, Map.get(step, "type", "pageview")) do
      "pageview" -> "/path"
      "custom_event" -> "event_name"
      "click_element" -> "#id or text:Button Text"
      _ -> "/path"
    end
  end

  defp goal_type_label("pageview"), do: "pageview"
  defp goal_type_label("custom_event"), do: "custom event"
  defp goal_type_label("click_element"), do: "click"
  defp goal_type_label(t), do: t

  defp format_money(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp format_money(_), do: "0.00"

  defp parse_revenue(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_revenue(n) when is_number(n), do: n / 1
  defp parse_revenue(_), do: 0.0
end
