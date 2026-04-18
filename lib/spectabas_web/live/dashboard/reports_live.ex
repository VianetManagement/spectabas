defmodule SpectabasWeb.Dashboard.ReportsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Saved reports management."

  alias Spectabas.{Accounts, Sites, Reports}
  import SpectabasWeb.Dashboard.SidebarComponent

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
      reports = Reports.list_reports(site)

      {:ok,
       socket
       |> assign(:page_title, "Reports - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:reports, reports)
       |> assign(:show_form, false)
       |> assign(:form, to_form(report_changeset()))}
    end
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  def handle_event("create_report", %{"report" => params}, socket) do
    if !Accounts.can_write?(socket.assigns.current_scope.user) do
      {:noreply, put_flash(socket, :error, "Viewers have read-only access.")}
    else
      case Reports.create_report(socket.assigns.site, socket.assigns.user, params) do
        {:ok, _report} ->
          reports = Reports.list_reports(socket.assigns.site)

          {:noreply,
           socket
           |> put_flash(:info, "Report created.")
           |> assign(:reports, reports)
           |> assign(:show_form, false)
           |> assign(:form, to_form(report_changeset()))}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    end
  end

  def handle_event("validate_report", %{"report" => params}, socket) do
    changeset =
      %Reports.Report{}
      |> Reports.Report.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  defp report_changeset do
    Reports.Report.changeset(%Reports.Report{}, %{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Reports"
      page_description="Scheduled and on-demand analytics reports."
      active="reports"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Reports</h1>
          </div>
          <button
            phx-click="toggle_form"
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
          >
            {if @show_form, do: "Cancel", else: "New Report"}
          </button>
        </div>

        <div :if={@show_form} class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Create Report</h2>
          <.form for={@form} phx-submit="create_report" phx-change="validate_report" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">Report Name</label>
                <input
                  type="text"
                  name="report[name]"
                  value={@form[:name].value}
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  required
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Schedule</label>
                <select
                  name="report[schedule]"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <option value="">No schedule (manual only)</option>
                  <option value="daily">Daily</option>
                  <option value="weekly">Weekly</option>
                  <option value="monthly">Monthly</option>
                </select>
              </div>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Description</label>
              <textarea
                name="report[description]"
                rows="2"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              ><%= @form[:description].value %></textarea>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">
                Recipients (comma-separated emails)
              </label>
              <input
                type="text"
                name="report[recipients_text]"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                placeholder="alice@example.com, bob@example.com"
              />
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Create Report
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
                  Schedule
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Last Sent
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Status
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@reports == []}>
                <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                  No reports configured.
                </td>
              </tr>
              <tr :for={report <- @reports} class="hover:bg-gray-50">
                <td class="px-6 py-4">
                  <div class="text-sm font-medium text-gray-900">{report.name}</div>
                  <div :if={report.description} class="text-sm text-gray-500">
                    {report.description}
                  </div>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">{report.schedule || "Manual"}</td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  {if report.last_sent_at,
                    do: Calendar.strftime(report.last_sent_at, "%Y-%m-%d %H:%M"),
                    else: "Never"}
                </td>
                <td class="px-6 py-4">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    if(report.active,
                      do: "bg-green-100 text-green-800",
                      else: "bg-gray-100 text-gray-800"
                    )
                  ]}>
                    {if report.active, do: "Active", else: "Inactive"}
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
end
