defmodule SpectabasWeb.Dashboard.EmailReportsLive do
  @moduledoc "Email report subscription management — configure periodic analytics digests."

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Reports}
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
      {:ok,
       socket
       |> assign(:page_title, "Email Reports - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> load_subscription()}
    end
  end

  @impl true
  def handle_event("save_report", %{"report" => params}, socket) do
    user = socket.assigns.user
    site = socket.assigns.site

    case Reports.upsert_email_subscription(user, site, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email report preferences saved.")
         |> load_subscription()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save report preferences.")}
    end
  end

  defp load_subscription(socket) do
    user = socket.assigns.user
    site = socket.assigns.site

    try do
      sub = Reports.get_email_subscription(user, site)

      socket
      |> assign(:report_frequency, if(sub, do: to_string(sub.frequency), else: "off"))
      |> assign(:report_hour, if(sub, do: sub.send_hour, else: 9))
      |> assign(:report_subscribers, Reports.list_email_subscriptions_for_site(site))
    rescue
      _ ->
        socket
        |> assign(:report_frequency, "off")
        |> assign(:report_hour, 9)
        |> assign(:report_subscribers, [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Email Reports"
      page_description="Receive periodic analytics digests by email."
      active="email-reports"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Email Reports</h1>
          </div>
        </div>

        <%!-- Your Preferences --%>
        <div class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-2">Your Preferences</h2>
          <p class="text-sm text-gray-500 mb-6">
            Configure your personal email report for this site. Each user can have their own settings.
          </p>
          <form phx-submit="save_report" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Frequency</label>
                <select
                  name="report[frequency]"
                  class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                >
                  <option value="off" selected={@report_frequency == "off"}>Off</option>
                  <option value="daily" selected={@report_frequency == "daily"}>Daily</option>
                  <option value="weekly" selected={@report_frequency == "weekly"}>Weekly</option>
                  <option value="monthly" selected={@report_frequency == "monthly"}>Monthly</option>
                </select>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Send Time</label>
                <select
                  name="report[send_hour]"
                  class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                >
                  <option :for={h <- 0..23} value={h} selected={@report_hour == h}>
                    {String.pad_leading(to_string(h), 2, "0")}:00
                  </option>
                </select>
                <p class="mt-1 text-xs text-gray-500">
                  In the site's timezone ({@site.timezone || "UTC"})
                </p>
              </div>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Save Preferences
              </button>
            </div>
          </form>
        </div>

        <%!-- What's Included --%>
        <div class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">What's Included</h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6 text-sm text-gray-600">
            <div>
              <h3 class="font-medium text-gray-900 mb-2">Summary Stats</h3>
              <p>
                Pageviews, visitors, sessions, bounce rate, and average duration — with percentage change vs the previous period.
              </p>
            </div>
            <div>
              <h3 class="font-medium text-gray-900 mb-2">Top Content</h3>
              <p>Top 5 pages, top 5 traffic sources, and top 5 countries by visitors.</p>
            </div>
            <div>
              <h3 class="font-medium text-gray-900 mb-2">Comparison Periods</h3>
              <p>
                Daily: today vs yesterday. Weekly: last 7 days vs prior 7 days. Monthly: this month vs last month.
              </p>
            </div>
            <div>
              <h3 class="font-medium text-gray-900 mb-2">Delivery</h3>
              <p>
                Sent at your chosen time in the site's timezone. Every email includes a one-click unsubscribe link.
              </p>
            </div>
          </div>
        </div>

        <%!-- Subscribers (admin view) --%>
        <div :if={@report_subscribers != []} class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Active Subscribers</h2>
            <p class="text-xs text-gray-500 mt-0.5">All users receiving reports for this site</p>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">User</th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Frequency
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Send Time
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Last Sent
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={sub <- @report_subscribers} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm text-gray-900">{sub.user.email}</td>
                <td class="px-6 py-4 text-sm text-gray-600 capitalize">{sub.frequency}</td>
                <td class="px-6 py-4 text-sm text-gray-600">
                  {String.pad_leading(to_string(sub.send_hour), 2, "0")}:00
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">{sub.last_sent_at || "Never"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
