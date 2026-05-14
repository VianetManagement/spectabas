defmodule SpectabasWeb.Dashboard.LanguagesLive do
  @moduledoc """
  Languages dashboard. Two signals:
  - **Browser language** — pulled from `navigator.language` on the
    visitor's device (e.g. "en-US", "fr-FR", "es"). What the visitor
    speaks / prefers.
  - **Page language** — pulled from `<html lang="...">` on the page
    they viewed (e.g. "en", "es"). What language your site served
    them.

  The cross-tab of those two reveals localization opportunities: who
  reaches your site in their non-native language, and which country
  segments speak which languages (often surprising — e.g. a large
  Spanish-speaking visitor base in Germany).
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics, DashboardSnapshots}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
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
        |> assign(:page_title, "Languages - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:summary, %{})
        |> assign(:browser_languages, [])
        |> assign(:page_languages, [])
        |> assign(:crosstab, [])
        |> assign(:mismatches, [])
        |> assign(:snapshot_refreshed_at, nil)
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    {data, refreshed_at} = load_kind(site, user, range)

    socket
    |> assign(:summary, data.summary)
    |> assign(:browser_languages, data.browser_languages)
    |> assign(:page_languages, data.page_languages)
    |> assign(:crosstab, data.crosstab)
    |> assign(:mismatches, data.mismatches)
    |> assign(:snapshot_refreshed_at, refreshed_at)
  end

  # Default 30d reads from the hourly languages snapshot (DashboardSnapshot
  # worker fans out per-site at :35 UTC). 7d / 90d fall back to live CH.
  defp load_kind(site, user, "30d") do
    case DashboardSnapshots.fetch(site, "languages") do
      {snap, refreshed_at} ->
        {%{
           summary: List.first(snap["summary"] || []) || %{},
           browser_languages: snap["browser_languages"] || [],
           page_languages: snap["page_languages"] || [],
           crosstab: Enum.take(snap["crosstab"] || [], 50),
           mismatches: snap["mismatches"] || []
         }, refreshed_at}

      nil ->
        {live_load(site, user, "30d"), nil}
    end
  end

  defp load_kind(site, user, range), do: {live_load(site, user, range), nil}

  defp live_load(site, user, range) do
    period = range_to_period(range)

    %{
      summary:
        case Analytics.language_summary(site, user, period) do
          {:ok, [row]} -> row
          _ -> %{}
        end,
      browser_languages:
        case Analytics.top_browser_languages(site, user, period) do
          {:ok, rows} -> rows
          _ -> []
        end,
      page_languages:
        case Analytics.top_page_languages(site, user, period) do
          {:ok, rows} -> rows
          _ -> []
        end,
      crosstab:
        case Analytics.language_country_crosstab(site, user, period) do
          {:ok, rows} -> Enum.take(rows, 50)
          _ -> []
        end,
      mismatches:
        case Analytics.language_mismatches(site, user, period) do
          {:ok, rows} -> rows
          _ -> []
        end
    }
  end

  defp mismatch_pct(summary) do
    mismatch = to_num(summary["mismatch_visitors"] || 0)
    total = to_num(summary["comparable_visitors"] || 0)
    if total > 0, do: Float.round(mismatch / total * 100, 1), else: 0.0
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Languages"
      page_description="Browser language (navigator.language) and page language (<html lang>), with country crosstab and mismatch detection."
      active="languages"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Languages</h1>
            <p class="text-sm text-gray-500 mt-1">
              What language are your visitors browsing in (navigator.language) and what language did your site serve them (&lt;html lang&gt;)? The cross-tab against country reveals diaspora / expat / multilingual segments. Mismatches surface visitors stuck on a non-native version of your site.
            </p>
            <p :if={@snapshot_refreshed_at} class="text-xs text-gray-400 mt-1">
              Snapshot · last update {DashboardSnapshots.refreshed_label(@snapshot_refreshed_at)}
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7 days"}, {"30d", "30 days"}, {"90d", "90 days"}]}
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
          <div class="grid grid-cols-2 md:grid-cols-3 gap-4 mb-6">
            <div class="bg-white rounded-lg shadow p-4">
              <p class="text-xs text-gray-500">Browser languages</p>
              <p class="text-2xl font-bold text-gray-900">
                {format_number(to_num(@summary["distinct_browser_languages"] || 0))}
              </p>
              <p class="text-[10px] text-gray-400 mt-0.5">distinct values seen</p>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <p class="text-xs text-gray-500">Page languages</p>
              <p class="text-2xl font-bold text-gray-900">
                {format_number(to_num(@summary["distinct_page_languages"] || 0))}
              </p>
              <p class="text-[10px] text-gray-400 mt-0.5">
                from &lt;html lang&gt; on rendered pages
              </p>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <p class="text-xs text-gray-500">Mismatch rate</p>
              <p class="text-2xl font-bold text-amber-700">{mismatch_pct(@summary)}%</p>
              <p class="text-[10px] text-gray-400 mt-0.5">
                {format_number(to_num(@summary["mismatch_visitors"] || 0))} of {format_number(
                  to_num(@summary["comparable_visitors"] || 0)
                )} visitors viewed a page in a different primary language than their browser
              </p>
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-100">
                <h2 class="text-sm font-semibold text-gray-700">Top browser languages</h2>
                <p class="text-[10px] text-gray-400 mt-0.5">
                  From <span class="font-mono">navigator.language</span>
                  — what the visitor's browser/OS is set to.
                </p>
              </div>
              <table class="min-w-full text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Language
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Pageviews
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :if={@browser_languages == []}>
                    <td colspan="3" class="px-5 py-6 text-center text-gray-400 text-xs">
                      No browser-language data in this range yet.
                    </td>
                  </tr>
                  <tr :for={r <- @browser_languages}>
                    <td class="px-5 py-2 font-mono text-xs">{r["language"]}</td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["unique_visitors"]))}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["pageviews"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-100">
                <h2 class="text-sm font-semibold text-gray-700">Top page languages</h2>
                <p class="text-[10px] text-gray-400 mt-0.5">
                  From <span class="font-mono">&lt;html lang&gt;</span>
                  on the rendered page — what your site served.
                </p>
              </div>
              <table class="min-w-full text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Language
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Pageviews
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :if={@page_languages == []}>
                    <td colspan="3" class="px-5 py-6 text-center text-gray-400 text-xs">
                      No page-language data in this range yet. If your pages don't set &lt;html lang&gt;, this stays empty — adding it is a one-line fix that also helps screen readers and search engines.
                    </td>
                  </tr>
                  <tr :for={r <- @page_languages}>
                    <td class="px-5 py-2 font-mono text-xs">{r["language"]}</td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["unique_visitors"]))}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["pageviews"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="bg-white rounded-lg shadow overflow-hidden mb-6">
            <div class="px-5 py-3 border-b border-gray-100">
              <h2 class="text-sm font-semibold text-gray-700">Language × country crosstab</h2>
              <p class="text-[10px] text-gray-400 mt-0.5">
                Browser language paired with the visitor's IP-derived country. The top rows are the dominant pairs; scroll for the unusual combinations that reveal diaspora / expat / multilingual segments worth targeting.
              </p>
            </div>
            <table class="min-w-full text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Language
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Country
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Visitors
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Pageviews
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@crosstab == []}>
                  <td colspan="4" class="px-5 py-6 text-center text-gray-400 text-xs">
                    No crosstab data in this range yet.
                  </td>
                </tr>
                <tr :for={r <- @crosstab}>
                  <td class="px-5 py-2 font-mono text-xs">{r["language"]}</td>
                  <td class="px-5 py-2 text-xs">{r["country"]}</td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["unique_visitors"]))}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["pageviews"]))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-100">
              <h2 class="text-sm font-semibold text-gray-700">Mismatches</h2>
              <p class="text-[10px] text-gray-400 mt-0.5">
                Visitor's browser language and the page's &lt;html lang&gt; differ by primary subtag (e.g. browser is <span class="font-mono">fr-CA</span>, page is <span class="font-mono">en</span>). Strong signal that a visitor is reading your site in a non-native language — typically means your language picker is hard to find, the auto-detect logic is off, or you don't have a translated version available.
              </p>
            </div>
            <table class="min-w-full text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Browser
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Page
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Visitors
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Pageviews
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@mismatches == []}>
                  <td colspan="4" class="px-5 py-6 text-center text-gray-400 text-xs">
                    No language mismatches in this range — every visitor saw a page in a language matching their browser primary.
                  </td>
                </tr>
                <tr :for={r <- @mismatches}>
                  <td class="px-5 py-2 font-mono text-xs">{r["browser_language"]}</td>
                  <td class="px-5 py-2 font-mono text-xs">{r["page_language"]}</td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["unique_visitors"]))}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["pageviews"]))}
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
end
