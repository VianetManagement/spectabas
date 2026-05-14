defmodule SpectabasWeb.Dashboard.CohortDetailLive do
  @moduledoc """
  Single cohort metrics view. Renders the cohort's filters as readable
  pills, then the standard set of cohort metrics (visitor stats, top
  pages, top sources, conversion rate by goal) over the last 30 days.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Cohorts}
  alias Spectabas.Cohorts.Cohort
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id, "id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      case Cohorts.get_for_site(site.id, id) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Cohort not found.")
           |> redirect(to: ~p"/dashboard/sites/#{site.id}/cohorts")}

        cohort ->
          {:ok,
           socket
           |> assign(:page_title, "#{cohort.name} - Cohorts - #{site.name}")
           |> assign(:site, site)
           |> assign(:user, user)
           |> assign(:cohort, cohort)
           |> assign(:metrics, Cohorts.metrics(cohort, user))}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title={@cohort.name}
      page_description="Cohort metrics over the last 30 days."
      active="cohorts"
      live_visitors={0}
    >
      <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/cohorts"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            ← Cohorts
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">{@cohort.name}</h1>
          <p :if={@cohort.description} class="text-sm text-gray-500 mt-1">{@cohort.description}</p>
          <div :if={Cohort.filters_list(@cohort) != []} class="mt-3 flex flex-wrap gap-2">
            <span
              :for={f <- Cohort.filters_list(@cohort)}
              class="inline-flex items-center px-2 py-0.5 rounded text-xs bg-indigo-50 text-indigo-700 font-mono"
            >
              {f["field"]} {pretty_op(f["op"])} {f["value"]}
            </span>
          </div>
          <div
            :if={@metrics.truncated}
            class="mt-3 inline-block px-3 py-1.5 rounded text-xs bg-amber-50 text-amber-900 border border-amber-200"
          >
            ⚠ Cohort matches more than 10,000 visitors in Postgres — results below are computed against the first 10,000 (sorted by visitor_id). Tighten the filters for an exact result.
          </div>
        </div>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Unique visitors</p>
            <p class="text-2xl font-bold text-gray-900">
              {format_number(to_num(@metrics.stats[:visitors] || 0))}
            </p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Pageviews</p>
            <p class="text-2xl font-bold text-gray-900">
              {format_number(to_num(@metrics.stats[:pageviews] || 0))}
            </p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Bounce rate</p>
            <p class="text-2xl font-bold text-gray-900">
              {@metrics.stats[:bounce_rate] || 0}%
            </p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Avg duration</p>
            <p class="text-2xl font-bold text-gray-900">
              {format_duration(to_num(@metrics.stats[:avg_duration] || 0))}
            </p>
          </div>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
          <div class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-100">
              <h2 class="text-sm font-semibold text-gray-700">Top pages</h2>
            </div>
            <table class="min-w-full text-sm">
              <tbody class="divide-y divide-gray-100">
                <tr :if={@metrics.top_pages == []}>
                  <td class="px-5 py-3 text-center text-gray-400 text-xs" colspan="2">
                    No data
                  </td>
                </tr>
                <tr :for={p <- @metrics.top_pages}>
                  <td class="px-5 py-2 font-mono text-xs truncate max-w-md">{p["url_path"]}</td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(p["pageviews"]))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-100">
              <h2 class="text-sm font-semibold text-gray-700">Top sources</h2>
            </div>
            <table class="min-w-full text-sm">
              <tbody class="divide-y divide-gray-100">
                <tr :if={@metrics.top_sources == []}>
                  <td class="px-5 py-3 text-center text-gray-400 text-xs" colspan="2">
                    No data
                  </td>
                </tr>
                <tr :for={s <- @metrics.top_sources}>
                  <td class="px-5 py-2 text-xs">{s["referrer_domain"] || s["source"] || "Direct"}</td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(s["sessions"] || s["visitors"] || 0))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div
          :if={map_size(@metrics.conversion_rate_by_goal) > 0}
          class="bg-white rounded-lg shadow overflow-hidden"
        >
          <div class="px-5 py-3 border-b border-gray-100">
            <h2 class="text-sm font-semibold text-gray-700">Goal conversion</h2>
            <p class="text-[10px] text-gray-400 mt-0.5">
              Cohort-scoped — completers and rate count only visitors matching the cohort's filters.
            </p>
          </div>
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">Goal</th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Completers
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">Rate</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={{_id, g} <- @metrics.conversion_rate_by_goal}>
                <td class="px-5 py-2 text-xs">{g.name}</td>
                <td class="px-5 py-2 text-right tabular-nums text-xs">
                  {format_number(to_num(g.completers))}
                </td>
                <td class="px-5 py-2 text-right tabular-nums text-xs">{g.rate}%</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp pretty_op("is"), do: "="
  defp pretty_op("is_not"), do: "≠"
  defp pretty_op("contains"), do: "⊇"
  defp pretty_op("not_contains"), do: "⊉"
  defp pretty_op(op), do: op
end
