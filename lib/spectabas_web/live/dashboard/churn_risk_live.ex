defmodule SpectabasWeb.Dashboard.ChurnRiskLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics, Visitors}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Churn Risk - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user} = socket.assigns

    rows =
      case Analytics.churn_risk_visitors(site, user) do
        {:ok, data} -> data
        _ -> []
      end

    # Enrich with emails
    visitor_ids = Enum.map(rows, & &1["visitor_id"])
    email_map = Visitors.emails_for_visitor_ids(visitor_ids)

    rows =
      Enum.map(rows, fn r ->
        case Map.get(email_map, r["visitor_id"]) do
          %{email: email} -> Map.put(r, "email", email)
          _ -> r
        end
      end)

    at_risk = length(rows)
    identified = Enum.count(rows, &Map.has_key?(&1, "email"))

    socket
    |> assign(:rows, rows)
    |> assign(:at_risk_count, at_risk)
    |> assign(:identified_count, identified)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Churn Risk"
      page_description="Customers with declining engagement who may be about to churn."
      active="churn-risk"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-gray-900">Churn Risk</h1>
          <p class="text-sm text-gray-500 mt-1">
            Customers whose engagement dropped significantly in the last 14 days vs the prior 14 days.
          </p>
        </div>

        <%= if @loading do %>
          <div class="bg-white rounded-lg shadow p-12 text-center">
            <div class="inline-flex items-center gap-3 text-gray-600">
              <svg class="animate-spin h-5 w-5 text-indigo-600" viewBox="0 0 24 24" fill="none">
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
              <span class="text-sm">Loading...</span>
            </div>
          </div>
        <% else %>
          <div class="grid grid-cols-2 md:grid-cols-3 gap-4 mb-8">
            <div class="bg-white rounded-lg shadow p-4">
              <dt class="text-xs font-medium text-gray-500 uppercase">At-Risk Customers</dt>
              <dd class="mt-1 text-3xl font-bold text-red-600">{format_number(@at_risk_count)}</dd>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <dt class="text-xs font-medium text-gray-500 uppercase">Identified (have email)</dt>
              <dd class="mt-1 text-3xl font-bold text-indigo-600">
                {format_number(@identified_count)}
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <dt class="text-xs font-medium text-gray-500 uppercase">Anonymous</dt>
              <dd class="mt-1 text-3xl font-bold text-gray-600">
                {format_number(@at_risk_count - @identified_count)}
              </dd>
            </div>
          </div>

          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Customer
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Prior Sessions
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Recent Sessions
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Session Decline
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Prior Pages
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Recent Pages
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Risk
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :if={@rows == []}>
                  <td colspan="7" class="px-6 py-8 text-center text-gray-500">
                    No at-risk customers detected. This is good!
                  </td>
                </tr>
                <tr :for={row <- @rows} class="hover:bg-gray-50">
                  <td class="px-6 py-4 text-sm">
                    <.link
                      navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{row["visitor_id"]}"}
                      class="text-indigo-600 hover:text-indigo-800"
                    >
                      <span :if={row["email"]} class="font-medium">{row["email"]}</span>
                      <span :if={!row["email"]} class="font-mono text-xs">
                        {String.slice(row["visitor_id"] || "", 0, 10)}...
                      </span>
                    </.link>
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row["prior_sessions"]))}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row["recent_sessions"]))}
                  </td>
                  <td class="px-6 py-4 text-sm text-right tabular-nums">
                    <span class={decline_color(row["session_decline_pct"])}>
                      {row["session_decline_pct"]}%
                    </span>
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row["prior_pages"]))}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(row["recent_pages"]))}
                  </td>
                  <td class="px-6 py-4 text-right">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-bold",
                      risk_level(row["session_decline_pct"])
                    ]}>
                      {risk_label(row["session_decline_pct"])}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp decline_color(pct) do
    p = parse_float(pct)

    cond do
      p >= 70 -> "text-red-600 font-bold"
      p >= 50 -> "text-orange-600 font-medium"
      true -> "text-yellow-600"
    end
  end

  defp risk_level(pct) do
    p = parse_float(pct)

    cond do
      p >= 70 -> "bg-red-100 text-red-800"
      p >= 50 -> "bg-orange-100 text-orange-800"
      true -> "bg-yellow-100 text-yellow-800"
    end
  end

  defp risk_label(pct) do
    p = parse_float(pct)

    cond do
      p >= 70 -> "High"
      p >= 50 -> "Medium"
      true -> "Low"
    end
  end

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(n) when is_number(n), do: n / 1
  defp parse_float(_), do: 0.0
end
