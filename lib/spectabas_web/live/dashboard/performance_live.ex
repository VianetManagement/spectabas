defmodule SpectabasWeb.Dashboard.PerformanceLive do
  use SpectabasWeb, :live_view

  @moduledoc "Real User Monitoring — Core Web Vitals and page load timing."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Performance - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    overview = safe_query(fn -> Analytics.rum_overview(site, user, period) end, %{})
    vitals = safe_query(fn -> Analytics.rum_web_vitals(site, user, period) end, %{})
    by_page = safe_query(fn -> Analytics.rum_by_page(site, user, period) end)
    by_device = safe_query(fn -> Analytics.rum_by_device(site, user, period) end)

    socket
    |> assign(:overview, overview)
    |> assign(:vitals, vitals)
    |> assign(:by_page, by_page)
    |> assign(:by_device, by_device)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Performance"
      page_description="Real User Monitoring — actual page load times and Core Web Vitals from your visitors' browsers."
      active="performance"
      live_visitors={0}
    >
      <div class="max-w-5xl mx-auto px-3 sm:px-6 lg:px-8 py-6">
        <%!-- Time range --%>
        <div class="flex items-center gap-2 mb-6">
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"24h", "24h"}, {"7d", "7 days"}, {"30d", "30 days"}]}
              phx-click="change_range"
              phx-value-range={elem(r, 0)}
              class={[
                "px-3 py-1.5 text-sm font-medium rounded-md",
                if(@date_range == elem(r, 0),
                  do: "bg-white shadow text-gray-900",
                  else: "text-gray-600 hover:text-gray-900"
                )
              ]}
            >
              {elem(r, 1)}
            </button>
          </nav>
          <span class="text-xs text-gray-500">
            {to_num(@overview["samples"])} samples
          </span>
        </div>

        <%!-- Core Web Vitals --%>
        <div class="bg-white rounded-lg shadow p-5 mb-6">
          <h3 class="font-semibold text-gray-900 mb-4">Core Web Vitals</h3>
          <div :if={to_num(@vitals["samples"]) == 0} class="text-sm text-gray-500 text-center py-4">
            No Core Web Vitals data yet. Data will appear after visitors load your site.
          </div>
          <div :if={to_num(@vitals["samples"]) > 0} class="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <.vital_card
              label="Largest Contentful Paint"
              abbrev="LCP"
              median={to_num(@vitals["median_lcp"])}
              p75={to_num(@vitals["p75_lcp"])}
              unit="ms"
              good={2500}
              poor={4000}
            />
            <.vital_card
              label="Cumulative Layout Shift"
              abbrev="CLS"
              median={to_float(@vitals["median_cls"])}
              p75={to_float(@vitals["p75_cls"])}
              unit=""
              good={0.1}
              poor={0.25}
            />
            <.vital_card
              label="First Input Delay"
              abbrev="FID"
              median={to_num(@vitals["median_fid"])}
              p75={to_num(@vitals["p75_fid"])}
              unit="ms"
              good={100}
              poor={300}
            />
          </div>
        </div>

        <%!-- Page Load Breakdown --%>
        <div class="bg-white rounded-lg shadow p-5 mb-6">
          <h3 class="font-semibold text-gray-900 mb-4">Page Load Timing (median)</h3>
          <div :if={to_num(@overview["samples"]) == 0} class="text-sm text-gray-500 text-center py-4">
            No performance data yet.
          </div>
          <div :if={to_num(@overview["samples"]) > 0} class="grid grid-cols-2 sm:grid-cols-4 gap-4">
            <.timing_card label="TTFB" value={to_num(@overview["median_ttfb"])} unit="ms" />
            <.timing_card label="First Paint" value={to_num(@overview["median_fcp"])} unit="ms" />
            <.timing_card label="DOM Ready" value={to_num(@overview["median_dom"])} unit="ms" />
            <.timing_card label="Full Load" value={to_num(@overview["median_page_load"])} unit="ms" />
          </div>
        </div>

        <%!-- Performance by Device --%>
        <div :if={@by_device != []} class="bg-white rounded-lg shadow overflow-x-auto mb-6">
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="font-semibold text-gray-900">Performance by Device</h3>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Device
                </th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Median Load
                </th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  P75 Load
                </th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Median FCP
                </th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Samples
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={d <- @by_device} class="hover:bg-gray-50">
                <td class="px-5 py-3 text-sm font-medium text-gray-900 capitalize">
                  {d["device_type"]}
                </td>
                <td class="px-5 py-3 text-sm text-right tabular-nums">
                  {format_ms(d["median_load"])}
                </td>
                <td class="px-5 py-3 text-sm text-right tabular-nums">{format_ms(d["p75_load"])}</td>
                <td class="px-5 py-3 text-sm text-right tabular-nums">
                  {format_ms(d["median_fcp"])}
                </td>
                <td class="px-5 py-3 text-sm text-right tabular-nums text-gray-500">
                  {format_number(to_num(d["samples"]))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Slowest Pages --%>
        <div :if={@by_page != []} class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="font-semibold text-gray-900">Slowest Pages</h3>
            <p class="text-xs text-gray-500 mt-0.5">
              Pages ranked by median load time (slowest first)
            </p>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-3 text-left text-xs font-medium text-gray-500 uppercase">Page</th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Median
                </th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">P75</th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">TTFB</th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">Size</th>
                <th class="px-5 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Samples
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={p <- @by_page} class="hover:bg-gray-50">
                <td class="px-5 py-3 text-sm">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/transitions?page=#{p["url_path"]}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {p["url_path"]}
                  </.link>
                </td>
                <td class={"px-5 py-3 text-sm text-right tabular-nums font-medium " <> load_color(p["median_load"])}>
                  {format_ms(p["median_load"])}
                </td>
                <td class="px-5 py-3 text-sm text-right tabular-nums">{format_ms(p["p75_load"])}</td>
                <td class="px-5 py-3 text-sm text-right tabular-nums">
                  {format_ms(p["median_ttfb"])}
                </td>
                <td class="px-5 py-3 text-sm text-right tabular-nums text-gray-500">
                  {format_bytes(p["avg_size"])}
                </td>
                <td class="px-5 py-3 text-sm text-right tabular-nums text-gray-500">
                  {format_number(to_num(p["samples"]))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp vital_card(assigns) do
    score = vital_score(assigns.p75, assigns.good, assigns.poor)

    assigns = Map.put(assigns, :score, score)

    ~H"""
    <div class={["rounded-lg border-2 p-4", vital_border(@score)]}>
      <div class="flex items-center justify-between mb-2">
        <span class="text-xs font-medium text-gray-500">{@label}</span>
        <span class={["text-xs font-bold px-2 py-0.5 rounded", vital_badge(@score)]}>
          {@score}
        </span>
      </div>
      <div class="text-2xl font-bold text-gray-900">
        {if @unit == "ms", do: format_ms(@median), else: @median}
      </div>
      <div class="text-xs text-gray-500 mt-1">
        p75: {if @unit == "ms", do: format_ms(@p75), else: @p75}
      </div>
    </div>
    """
  end

  defp timing_card(assigns) do
    ~H"""
    <div class="bg-gray-50 rounded-lg p-3">
      <div class="text-xs font-medium text-gray-500">{@label}</div>
      <div class="text-xl font-bold text-gray-900 mt-1">{format_ms(@value)}</div>
    </div>
    """
  end

  # Public for testing
  @doc false
  def vital_score(p75, good, poor) do
    cond do
      p75 <= good -> "Good"
      p75 <= poor -> "Needs Work"
      true -> "Poor"
    end
  end

  defp vital_border("Good"), do: "border-green-200 bg-green-50"
  defp vital_border("Needs Work"), do: "border-amber-200 bg-amber-50"
  defp vital_border("Poor"), do: "border-red-200 bg-red-50"
  defp vital_border(_), do: "border-gray-200"

  defp vital_badge("Good"), do: "bg-green-100 text-green-800"
  defp vital_badge("Needs Work"), do: "bg-amber-100 text-amber-800"
  defp vital_badge("Poor"), do: "bg-red-100 text-red-800"
  defp vital_badge(_), do: "bg-gray-100 text-gray-800"

  defp load_color(ms) do
    ms = to_num(ms)

    cond do
      ms <= 1000 -> "text-green-600"
      ms <= 3000 -> "text-amber-600"
      true -> "text-red-600"
    end
  end

  @doc false
  def format_bytes(bytes) do
    bytes = to_num(bytes)

    cond do
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)}MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)}KB"
      bytes > 0 -> "#{bytes}B"
      true -> "-"
    end
  end
end
