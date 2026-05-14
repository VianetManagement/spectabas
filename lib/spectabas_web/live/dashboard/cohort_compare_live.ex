defmodule SpectabasWeb.Dashboard.CohortCompareLive do
  @moduledoc """
  Side-by-side comparison of two cohorts on the same shared metrics
  (visitors, pageviews, bounce rate, avg duration, top pages, top
  sources, goals). Linked from `CohortsLive`'s "Compare two cohorts"
  picker.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Cohorts}
  alias Spectabas.Cohorts.Cohort
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      with {a_id, _} <- Integer.parse(params["a"] || ""),
           {b_id, _} <- Integer.parse(params["b"] || ""),
           %Cohort{} = a <- Cohorts.get_for_site(site.id, a_id),
           %Cohort{} = b <- Cohorts.get_for_site(site.id, b_id) do
        {:ok,
         socket
         |> assign(:page_title, "#{a.name} vs #{b.name} - Cohorts - #{site.name}")
         |> assign(:site, site)
         |> assign(:user, user)
         |> assign(:cohort_a, a)
         |> assign(:cohort_b, b)
         |> assign(:metrics_a, Cohorts.metrics(a, user))
         |> assign(:metrics_b, Cohorts.metrics(b, user))}
      else
        _ ->
          {:ok,
           socket
           |> put_flash(:error, "Pick two valid cohorts to compare.")
           |> redirect(to: ~p"/dashboard/sites/#{site.id}/cohorts")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Cohort comparison"
      page_description="Two cohorts side-by-side on the same metrics."
      active="cohorts"
      live_visitors={0}
    >
      <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/cohorts"}
          class="text-sm text-indigo-600 hover:text-indigo-800"
        >
          ← Cohorts
        </.link>
        <h1 class="text-2xl font-bold text-gray-900 mt-2">
          {@cohort_a.name} <span class="text-gray-400 mx-2">vs</span> {@cohort_b.name}
        </h1>

        <%!-- Side-by-side stat cards --%>
        <div class="grid grid-cols-2 gap-6 mt-6">
          <.cohort_stats_panel cohort={@cohort_a} metrics={@metrics_a} accent="indigo" />
          <.cohort_stats_panel cohort={@cohort_b} metrics={@metrics_b} accent="emerald" />
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  attr :cohort, :map, required: true
  attr :metrics, :map, required: true
  attr :accent, :string, default: "indigo"

  defp cohort_stats_panel(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow overflow-hidden">
      <div class={"px-5 py-3 border-b border-gray-100 bg-#{@accent}-50/40"}>
        <h2 class="text-sm font-semibold text-gray-900">{@cohort.name}</h2>
        <p :if={@cohort.description} class="text-xs text-gray-500 mt-0.5">{@cohort.description}</p>
      </div>
      <div class="p-5 space-y-4">
        <div class="grid grid-cols-2 gap-3 text-sm">
          <div>
            <p class="text-[10px] text-gray-400 uppercase">Visitors</p>
            <p class="text-xl font-bold text-gray-900">
              {format_number(to_num(@metrics.stats[:visitors] || 0))}
            </p>
          </div>
          <div>
            <p class="text-[10px] text-gray-400 uppercase">Pageviews</p>
            <p class="text-xl font-bold text-gray-900">
              {format_number(to_num(@metrics.stats[:pageviews] || 0))}
            </p>
          </div>
          <div>
            <p class="text-[10px] text-gray-400 uppercase">Bounce rate</p>
            <p class="text-xl font-bold text-gray-900">{@metrics.stats[:bounce_rate] || 0}%</p>
          </div>
          <div>
            <p class="text-[10px] text-gray-400 uppercase">Avg duration</p>
            <p class="text-xl font-bold text-gray-900">
              {format_duration(to_num(@metrics.stats[:avg_duration] || 0))}
            </p>
          </div>
        </div>

        <div>
          <p class="text-[10px] text-gray-400 uppercase mb-1">Top pages</p>
          <ul class="text-xs space-y-0.5">
            <li :for={p <- Enum.take(@metrics.top_pages, 5)} class="flex justify-between">
              <span class="font-mono text-gray-700 truncate">{p["url_path"]}</span>
              <span class="text-gray-500 tabular-nums">
                {format_number(to_num(p["pageviews"]))}
              </span>
            </li>
            <li :if={@metrics.top_pages == []} class="text-gray-400 italic">No data</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end
end
