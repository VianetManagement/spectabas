defmodule SpectabasWeb.Admin.ScraperLabelsLive do
  @moduledoc """
  Admin report for accumulated scraper labels (Stage 1 of the
  scraper-label learning loop — see `docs/scraper-labels.md`). Surfaces:

  - Where current rules disagree with human judgment (false positives /
    negatives) so we can hand-tune weights.
  - Per-signal correlation between firing and human "scraper" label so we
    can spot under- and over-weighted signals at a glance.

  No model is involved. The verdict column is heuristic. Pick a site from
  the dropdown; the report scopes to that site.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{ScraperLabels, Sites}

  @impl true
  def mount(params, _session, socket) do
    sites = Sites.list_sites() |> Enum.sort_by(& &1.name)
    default_site = pick_default_site(sites, params["site_id"])

    {:ok,
     socket
     |> assign(:page_title, "Scraper Labels Report")
     |> assign(:sites, sites)
     |> assign(:site, default_site)
     |> assign_report(default_site)}
  end

  @impl true
  def handle_event("select_site", %{"site_id" => site_id}, socket) do
    site = Enum.find(socket.assigns.sites, &(to_string(&1.id) == site_id))

    {:noreply,
     socket
     |> assign(:site, site)
     |> assign_report(site)}
  end

  defp pick_default_site([], _requested), do: nil

  defp pick_default_site(sites, requested) when is_binary(requested) do
    Enum.find(sites, hd(sites), &(to_string(&1.id) == requested))
  end

  defp pick_default_site(sites, _requested), do: hd(sites)

  defp assign_report(socket, nil), do: assign(socket, :report, nil)

  defp assign_report(socket, site) do
    assign(socket, :report, ScraperLabels.signal_correlation_report(site.id))
  end

  defp verdict_class(:underweighted), do: "bg-amber-100 text-amber-800"
  defp verdict_class(:overweighted), do: "bg-rose-100 text-rose-800"
  defp verdict_class(:weak_signal), do: "bg-gray-100 text-gray-600"
  defp verdict_class(:too_few_labels), do: "bg-gray-50 text-gray-400"
  defp verdict_class(_), do: "bg-green-50 text-green-700"

  defp verdict_label(:underweighted), do: "underweighted"
  defp verdict_label(:overweighted), do: "overweighted"
  defp verdict_label(:weak_signal), do: "weak signal"
  defp verdict_label(:too_few_labels), do: "too few labels"
  defp verdict_label(_), do: "ok"

  defp format_ratio(:infinity), do: "∞"
  defp format_ratio(r) when is_number(r), do: "#{r}×"

  defp active_signals(signals) when is_map(signals) do
    signals
    |> Enum.filter(fn {_k, v} -> v == true end)
    |> Enum.map(fn {k, _} -> k end)
    |> Enum.sort()
  end

  defp active_signals(_), do: []

  defp short_visitor(id) when is_binary(id), do: String.slice(id, 0..11) <> "…"
  defp short_visitor(_), do: "?"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-6">
        <h1 class="text-2xl font-bold text-gray-900">Scraper Labels Report</h1>
        <p class="text-sm text-gray-500 mt-1">
          Read only of <code class="text-xs">scraper_labels</code>
          — what the team has manually classified, and where the current rules disagree. High-confidence labels only (source_weight ≥ 0.7).
        </p>
      </div>

      <%!-- Site picker --%>
      <div class="bg-white rounded-lg shadow p-4 mb-6">
        <form phx-change="select_site" class="flex items-center gap-3">
          <label for="site_id" class="text-sm font-medium text-gray-700">Site:</label>
          <select
            name="site_id"
            id="site_id"
            class="text-sm rounded border-gray-300 py-1.5 pr-8 min-w-[260px]"
          >
            <option :for={s <- @sites} value={s.id} selected={@site && @site.id == s.id}>
              {s.name} ({s.domain})
            </option>
          </select>
        </form>
      </div>

      <%= if @report do %>
        <%!-- Summary --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">High-conf scraper labels</p>
            <p class="text-2xl font-bold text-rose-700">{@report.n_scraper}</p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">High-conf not-scraper labels</p>
            <p class="text-2xl font-bold text-green-700">{@report.n_not_scraper}</p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">False positives (score≥85, whitelisted)</p>
            <p class="text-2xl font-bold text-amber-700">{length(@report.false_positives)}</p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">False negatives (score&lt;40, flagged)</p>
            <p class="text-2xl font-bold text-amber-700">{length(@report.false_negatives)}</p>
          </div>
        </div>

        <%!-- Counts by source --%>
        <div class="bg-white rounded-lg shadow mb-8 overflow-hidden">
          <div class="px-5 py-3 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Labels by source</h2>
            <p class="text-xs text-gray-500 mt-0.5">
              All labels — including the auto-fired ones the analysis excludes.
            </p>
          </div>
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Source
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Label
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Count
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={@report.counts_by_source == []}>
                <td colspan="3" class="px-5 py-3 text-center text-gray-400 text-xs">
                  No labels yet
                </td>
              </tr>
              <tr :for={{label, source, count} <- @report.counts_by_source}>
                <td class="px-5 py-2 font-mono text-xs">{source}</td>
                <td class="px-5 py-2">
                  <span class={[
                    "inline-flex px-2 py-0.5 rounded text-xs font-medium",
                    if(label == "scraper",
                      do: "bg-rose-100 text-rose-700",
                      else: "bg-green-100 text-green-700"
                    )
                  ]}>
                    {label}
                  </span>
                </td>
                <td class="px-5 py-2 text-right tabular-nums">{count}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Signal correlation table --%>
        <div class="bg-white rounded-lg shadow mb-8 overflow-hidden">
          <div class="px-5 py-3 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Signal correlation</h2>
            <p class="text-xs text-gray-500 mt-0.5">
              For each signal: how often it fired on scraper-labeled visitors vs not-scraper. Ratio &gt; 1 means the signal correctly predicts scraper. Verdict is heuristic — eyeball the numbers, don't auto-update weights.
            </p>
          </div>
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Signal
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Scraper
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Not-scraper
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Ratio
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Weight
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Verdict
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={row <- @report.signal_stats}>
                <td class="px-5 py-2 font-mono text-xs">{row.signal}</td>
                <td class="px-5 py-2 text-right text-xs tabular-nums">
                  {row.scraper_count}/{@report.n_scraper}
                  <span class="text-gray-400 ml-1">({row.scraper_pct}%)</span>
                </td>
                <td class="px-5 py-2 text-right text-xs tabular-nums">
                  {row.not_scraper_count}/{@report.n_not_scraper}
                  <span class="text-gray-400 ml-1">({row.not_scraper_pct}%)</span>
                </td>
                <td class="px-5 py-2 text-right tabular-nums">{format_ratio(row.ratio)}</td>
                <td class="px-5 py-2 text-right tabular-nums text-gray-700">
                  {row.current_weight}
                </td>
                <td class="px-5 py-2">
                  <span class={[
                    "inline-flex px-2 py-0.5 rounded text-xs font-medium",
                    verdict_class(row.verdict)
                  ]}>
                    {verdict_label(row.verdict)}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- False positives --%>
        <div class="bg-white rounded-lg shadow mb-8 overflow-hidden">
          <div class="px-5 py-3 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">False positives</h2>
            <p class="text-xs text-gray-500 mt-0.5">
              Visitors scored ≥85 (current tier: <em>certain</em>) but whitelisted/unflagged by a human. These rows tell you which signal combinations are too aggressive.
            </p>
          </div>
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Email
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Score
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Active signals
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  When
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={@report.false_positives == []}>
                <td colspan="5" class="px-5 py-3 text-center text-gray-400 text-xs">None</td>
              </tr>
              <tr :for={fp <- @report.false_positives} class="hover:bg-gray-50">
                <td class="px-5 py-2">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{fp.visitor_id}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {short_visitor(fp.visitor_id)}
                  </.link>
                </td>
                <td class="px-5 py-2 text-xs text-gray-600">{fp.email || "—"}</td>
                <td class="px-5 py-2 text-right tabular-nums font-semibold">{fp.score}</td>
                <td class="px-5 py-2 text-xs text-gray-600">
                  <span
                    :for={s <- active_signals(fp.signals)}
                    class="inline-block px-1.5 py-0.5 mr-1 mb-0.5 rounded bg-rose-50 text-rose-700 font-mono text-[10px]"
                  >
                    {s}
                  </span>
                </td>
                <td class="px-5 py-2 text-xs text-gray-500">
                  {Calendar.strftime(fp.labeled_at, "%Y-%m-%d %H:%M")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- False negatives --%>
        <div class="bg-white rounded-lg shadow mb-8 overflow-hidden">
          <div class="px-5 py-3 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">False negatives</h2>
            <p class="text-xs text-gray-500 mt-0.5">
              Visitors scored &lt;40 (below the <em>watching</em>
              tier) but a human manually flagged them. These rows tell you which signal combinations the rules are missing.
            </p>
          </div>
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Email
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Score
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Active signals
                </th>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  When
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={@report.false_negatives == []}>
                <td colspan="5" class="px-5 py-3 text-center text-gray-400 text-xs">None</td>
              </tr>
              <tr :for={fn_row <- @report.false_negatives} class="hover:bg-gray-50">
                <td class="px-5 py-2">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{fn_row.visitor_id}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {short_visitor(fn_row.visitor_id)}
                  </.link>
                </td>
                <td class="px-5 py-2 text-xs text-gray-600">{fn_row.email || "—"}</td>
                <td class="px-5 py-2 text-right tabular-nums font-semibold">{fn_row.score}</td>
                <td class="px-5 py-2 text-xs text-gray-600">
                  <span
                    :for={s <- active_signals(fn_row.signals)}
                    class="inline-block px-1.5 py-0.5 mr-1 mb-0.5 rounded bg-amber-50 text-amber-700 font-mono text-[10px]"
                  >
                    {s}
                  </span>
                  <span :if={active_signals(fn_row.signals) == []} class="text-gray-400 italic">
                    no signals captured
                  </span>
                </td>
                <td class="px-5 py-2 text-xs text-gray-500">
                  {Calendar.strftime(fn_row.labeled_at, "%Y-%m-%d %H:%M")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% else %>
        <div class="bg-white rounded-lg shadow p-10 text-center text-gray-400">
          No sites available.
        </div>
      <% end %>
    </div>
    """
  end
end
