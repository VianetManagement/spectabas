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

    unless Accounts.can_access_site?(user, site) do
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
       |> assign(:form_steps, [%{name: "", type: "pageview", value: ""}])}
    end
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
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

  def handle_event("update_step", %{"index" => index, "field" => field, "value" => value}, socket) do
    idx = String.to_integer(index)
    steps = List.update_at(socket.assigns.form_steps, idx, &Map.put(&1, field, value))
    {:noreply, assign(socket, :form_steps, steps)}
  end

  def handle_event("update_name", %{"value" => name}, socket) do
    {:noreply, assign(socket, :form_name, name)}
  end

  def handle_event("create_funnel", _params, socket) do
    params = %{
      "name" => socket.assigns.form_name,
      "steps" => socket.assigns.form_steps
    }

    case Goals.create_funnel(socket.assigns.site, params) do
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
          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-gray-700">Funnel Name</label>
              <input
                type="text"
                phx-blur="update_name"
                value={@form_name}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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
                  <select
                    phx-change="update_step"
                    phx-value-index={idx}
                    phx-value-field="type"
                    class="rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  >
                    <option
                      value="pageview"
                      selected={step["type"] == "pageview" || Map.get(step, :type) == "pageview"}
                    >
                      Pageview
                    </option>
                    <option
                      value="custom_event"
                      selected={
                        step["type"] == "custom_event" || Map.get(step, :type) == "custom_event"
                      }
                    >
                      Custom Event
                    </option>
                  </select>
                  <input
                    type="text"
                    phx-blur="update_step"
                    phx-value-index={idx}
                    phx-value-field="value"
                    value={step["value"] || Map.get(step, :value, "")}
                    placeholder={
                      if(Map.get(step, :type, "pageview") == "pageview",
                        do: "/path",
                        else: "event_name"
                      )
                    }
                    class="flex-1 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  />
                  <button
                    :if={length(@form_steps) > 1}
                    phx-click="remove_step"
                    phx-value-index={idx}
                    class="text-red-500 hover:text-red-700 text-sm"
                  >
                    Remove
                  </button>
                </div>
              </div>
              <button phx-click="add_step" class="mt-3 text-sm text-indigo-600 hover:text-indigo-800">
                + Add step
              </button>
            </div>
            <div class="flex justify-end">
              <button
                phx-click="create_funnel"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Create Funnel
              </button>
            </div>
          </div>
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
              <tr
                :for={funnel <- @funnels}
                phx-click="view_funnel"
                phx-value-id={funnel.id}
                class="hover:bg-indigo-50 cursor-pointer transition-colors"
              >
                <td class="px-6 py-4 text-sm font-medium text-gray-900">{funnel.name}</td>
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
