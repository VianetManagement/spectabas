defmodule SpectabasWeb.Dashboard.SEOLive do
  @moduledoc """
  Dedicated SEO section at `/dashboard/sites/:site_id/seo`. Lists the
  latest audit per URL with score, issue counts, response time, and a
  click-through to the per-page detail view's SEO tab.

  The page is admin-facing — analysts and viewers can browse. Bulk
  audit / single-URL audit / settings actions are gated on
  `Accounts.can_write?/1` so viewers see a read-only list.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, SEO}
  import SpectabasWeb.Dashboard.SidebarComponent

  @write_events ~w(audit_url bulk_audit)

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket = maybe_attach_viewer_guard(socket, user)

      {:ok,
       socket
       |> assign(:page_title, "SEO - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:can_write, Accounts.can_write?(user))
       |> assign(:headless_configured, SEO.HeadlessClient.configured?())
       |> assign(:sort, :score_asc)
       |> assign(:audit_url_input, "")
       |> assign(:expanded_audit_id, nil)
       |> load_audits()}
    end
  end

  defp maybe_attach_viewer_guard(socket, user) do
    if Accounts.can_write?(user) do
      socket
    else
      attach_hook(socket, :viewer_seo_guard, :handle_event, fn
        event, _params, sock when event in @write_events ->
          {:halt, put_flash(sock, :error, "Viewers can't trigger SEO audits.")}

        _event, _params, sock ->
          {:cont, sock}
      end)
    end
  end

  @impl true
  def handle_event("change_sort", %{"sort" => s}, socket) do
    sort =
      case s do
        "score_asc" -> :score_asc
        "score_desc" -> :score_desc
        "url" -> :url
        "recent" -> :recent
        _ -> :score_asc
      end

    {:noreply, socket |> assign(:sort, sort) |> load_audits()}
  end

  def handle_event("update_audit_url", %{"audit_url_input" => v}, socket) do
    {:noreply, assign(socket, :audit_url_input, v)}
  end

  def handle_event("toggle_audit", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)

    expanded =
      if socket.assigns.expanded_audit_id == id, do: nil, else: id

    {:noreply, assign(socket, :expanded_audit_id, expanded)}
  end

  def handle_event("audit_url", _params, socket) do
    url = String.trim(socket.assigns.audit_url_input || "")

    cond do
      url == "" ->
        {:noreply, put_flash(socket, :error, "Enter a URL to audit.")}

      not String.starts_with?(url, "http") ->
        {:noreply, put_flash(socket, :error, "URL must start with http:// or https://")}

      true ->
        case SEO.enqueue_audit(socket.assigns.site, url, trigger: "on_demand") do
          {:ok, _job} ->
            {:noreply,
             socket
             |> assign(:audit_url_input, "")
             |> put_flash(:info, "Audit queued for #{url}. Refresh in a few seconds.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to enqueue audit: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("bulk_audit", _params, socket) do
    %{site: site} = socket.assigns
    remaining = SEO.budget_remaining(site)

    if remaining == 0 do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Weekly budget exhausted (#{site.seo_crawl_budget} pages). Resets Monday or increase budget in Site Settings."
       )}
    else
      enqueued = enqueue_top_pages(site, remaining)

      {:noreply,
       put_flash(
         socket,
         :info,
         "Enqueued #{enqueued} audit(s). Budget remaining: #{remaining - enqueued}."
       )}
    end
  end

  defp enqueue_top_pages(site, budget) do
    # Pick URLs from the latest 30 days of pageviews ordered by traffic,
    # capped at the remaining budget. URL is the rendered full URL —
    # `url_host` + `url_path`.
    rows =
      case Spectabas.Analytics.top_pages(site, system_user(), :month) do
        {:ok, list} -> list
        _ -> []
      end

    rows
    |> Stream.map(&row_to_url(&1, site))
    |> Stream.reject(&is_nil/1)
    |> Stream.uniq()
    |> Enum.take(budget)
    |> Enum.reduce(0, fn url, acc ->
      case SEO.enqueue_audit(site, url, trigger: "scheduled") do
        {:ok, _job} -> acc + 1
        _ -> acc
      end
    end)
  end

  defp row_to_url(row, site) do
    path = row["url_path"] || row[:url_path]
    SEO.build_audit_url(site, path)
  end

  defp system_user, do: %Spectabas.Accounts.User{role: :platform_admin}

  defp load_audits(socket) do
    audits = SEO.latest_per_url(socket.assigns.site.id, order: socket.assigns.sort, limit: 200)
    assign(socket, :audits, audits)
  end

  defp score_class(_score, %{error: e}) when is_binary(e) and e != "",
    do: "bg-gray-200 text-gray-700"

  defp score_class(nil, _), do: "bg-gray-100 text-gray-500"

  defp score_class(s, _) when is_integer(s) do
    cond do
      s >= 80 -> "bg-emerald-100 text-emerald-800"
      s >= 60 -> "bg-amber-100 text-amber-800"
      true -> "bg-rose-100 text-rose-800"
    end
  end

  # Display the score, or "Failed" when the fetch errored out (rather
  # than a confusing 0 with no obvious cause).
  defp score_display(%{error: e}) when is_binary(e) and e != "", do: "Failed"
  defp score_display(%{score: nil}), do: "—"
  defp score_display(%{score: s}), do: s

  defp severity_breakdown(%{issues: %{"items" => items}}) when is_list(items) do
    items
    |> Enum.frequencies_by(&Map.get(&1, "severity"))
  end

  defp severity_breakdown(_), do: %{}

  # Human-readable summary in the Issues column. Single-line, no
  # cryptic abbreviations. Examples:
  #   "Fetch failed"          (when score=0 + error set)
  #   "Looks good"            (zero issues)
  #   "1 critical, 2 major"   (the typical case)
  defp render_issue_summary(%{error: e} = _audit) when is_binary(e) and e != "" do
    assigns = %{e: e}

    ~H"""
    <span class="text-rose-700 font-medium">Fetch failed</span>
    """
  end

  defp render_issue_summary(audit) do
    items = (audit.issues && audit.issues["items"]) || []
    breakdown = severity_breakdown(audit)
    crit = Map.get(breakdown, "critical", 0)
    major = Map.get(breakdown, "major", 0)
    minor = Map.get(breakdown, "minor", 0)

    assigns = %{items: items, crit: crit, major: major, minor: minor}

    ~H"""
    <span :if={@items == []} class="text-emerald-700 font-medium">Looks good</span>
    <span :if={@items != []} class="text-gray-700">
      <span :if={@crit > 0} class="text-rose-700 font-medium">
        {@crit} critical
      </span>
      <span :if={@crit > 0 and (@major > 0 or @minor > 0)} class="text-gray-400">, </span>
      <span :if={@major > 0} class="text-amber-700">
        {@major} major
      </span>
      <span :if={@major > 0 and @minor > 0} class="text-gray-400">, </span>
      <span :if={@minor > 0} class="text-gray-500">
        {@minor} minor
      </span>
    </span>
    """
  end

  # Expanded detail row shown when a user clicks an audit. Lists each
  # issue with severity, a plain-English message, and key metadata so
  # the user can act on it without leaving the page.
  defp render_audit_detail(audit) do
    items = (audit.issues && audit.issues["items"]) || []
    assigns = %{audit: audit, items: items}

    ~H"""
    <div class="space-y-3">
      <div :if={@audit.error} class="bg-rose-50 border border-rose-200 rounded p-3">
        <p class="text-xs font-semibold text-rose-900 mb-1">Fetch error</p>
        <p class="text-xs text-rose-800 font-mono break-all">{@audit.error}</p>
        <p class="text-xs text-rose-800 mt-2">
          The headless browser couldn't fetch this URL. Common causes:
          Cloudflare / WAF blocking the request, the URL returning a non-200 status, the page taking longer than the per-request timeout, or the Playwright sidecar service being unreachable. Check Site Settings → Content → SEO audit for the Cloudflare allow-rule recipe.
        </p>
      </div>

      <div :if={@items != []}>
        <p class="text-xs font-semibold text-gray-700 mb-2">Issues to fix</p>
        <ul class="space-y-2">
          <li
            :for={issue <- @items}
            class={[
              "border-l-4 pl-3 py-1",
              case issue["severity"] do
                "critical" -> "border-rose-500 bg-rose-50"
                "major" -> "border-amber-500 bg-amber-50"
                _ -> "border-gray-300 bg-gray-50"
              end
            ]}
          >
            <p class="text-[10px] font-semibold uppercase tracking-wide text-gray-500">
              {issue["severity"]}
            </p>
            <p class="text-xs text-gray-800">{issue["message"]}</p>
          </li>
        </ul>
      </div>

      <div :if={@items == [] and !@audit.error} class="text-xs text-emerald-700">
        ✓ No issues detected on this page.
      </div>

      <div class="grid grid-cols-2 md:grid-cols-4 gap-2 text-xs pt-3 border-t border-gray-200">
        <div>
          <p class="text-gray-500">Title length</p>
          <p class="text-gray-900 tabular-nums">
            {if @audit.title, do: String.length(@audit.title), else: "—"}
          </p>
        </div>
        <div>
          <p class="text-gray-500">Meta length</p>
          <p class="text-gray-900 tabular-nums">
            {if @audit.meta_description, do: String.length(@audit.meta_description), else: "—"}
          </p>
        </div>
        <div>
          <p class="text-gray-500">Word count</p>
          <p class="text-gray-900 tabular-nums">{@audit.word_count || "—"}</p>
        </div>
        <div>
          <p class="text-gray-500">Internal / External links</p>
          <p class="text-gray-900 tabular-nums">
            {@audit.internal_link_count || 0} / {@audit.external_link_count || 0}
          </p>
        </div>
        <div>
          <p class="text-gray-500">Image alt coverage</p>
          <p class="text-gray-900 tabular-nums">
            {alt_pct(@audit)}
          </p>
        </div>
        <div>
          <p class="text-gray-500">Status code</p>
          <p class="text-gray-900 tabular-nums">{@audit.status_code || "—"}</p>
        </div>
        <div>
          <p class="text-gray-500">Schema types</p>
          <p class="text-gray-900 truncate">
            {if @audit.schema_types && @audit.schema_types != [],
              do: Enum.join(@audit.schema_types, ", "),
              else: "—"}
          </p>
        </div>
        <div>
          <p class="text-gray-500">Canonical</p>
          <p class="text-gray-900 font-mono truncate text-[11px]">
            {@audit.canonical || "—"}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp alt_pct(%{image_count: 0}), do: "—"
  defp alt_pct(%{image_count: nil}), do: "—"

  defp alt_pct(%{image_count: ic, image_alt_count: ac}) when is_integer(ic) and ic > 0 do
    "#{round(ac / ic * 100)}% (#{ac} of #{ic})"
  end

  defp alt_pct(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="SEO"
      page_description="Per-page SEO audit — real-browser crawl with title / meta / H1 / canonical / schema / link / image-alt checks."
      active="seo"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-gray-900">SEO audit</h1>
          <p class="text-sm text-gray-500 mt-1">
            Every page audited in a real Chromium browser via the SEO sidecar service. Score is 0-100, computed from title / meta / H1 / canonical / schema / image-alt / response-time / word-count checks. Click any row for the per-page deep-dive with issue explanations.
          </p>
        </div>

        <div
          :if={!@headless_configured}
          class="bg-amber-50 border border-amber-200 rounded-lg p-4 mb-6"
        >
          <p class="text-sm text-amber-900">
            <strong>Headless service not configured.</strong>
            Set the <code class="text-xs bg-amber-100 px-1 rounded">PLAYWRIGHT_URL</code>
            env var on the Render web service to point at the Playwright sidecar (see <code class="text-xs bg-amber-100 px-1 rounded">playwright-sidecar/README.md</code>). Until then, audit attempts will record fetch failures.
          </p>
        </div>

        <div class="bg-white rounded-lg shadow p-5 mb-6">
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <p class="text-xs text-gray-500">Pages audited</p>
              <p class="text-2xl font-bold text-gray-900">{length(@audits)}</p>
            </div>
            <div>
              <p class="text-xs text-gray-500">Weekly budget</p>
              <p class="text-2xl font-bold text-gray-900">{@site.seo_crawl_budget}</p>
              <p class="text-[10px] text-gray-400 mt-0.5">
                {SEO.budget_remaining(@site)} remaining this week
              </p>
            </div>
            <div>
              <p class="text-xs text-gray-500">Avg score</p>
              <p class="text-2xl font-bold text-gray-900">
                {avg_score(@audits)}
              </p>
            </div>
            <div>
              <p class="text-xs text-gray-500">Critical issues</p>
              <p class="text-2xl font-bold text-rose-700">{critical_count(@audits)}</p>
            </div>
          </div>
        </div>

        <div :if={@can_write} class="bg-white rounded-lg shadow p-5 mb-6">
          <div class="flex items-center justify-between gap-4 flex-wrap">
            <div>
              <h2 class="text-sm font-semibold text-gray-700">Run audit</h2>
              <p class="text-xs text-gray-500 mt-1">
                Paste a URL for an on-demand audit (doesn't count toward weekly budget), or trigger a bulk audit of top pages by traffic.
              </p>
            </div>
            <div class="flex gap-2">
              <button
                phx-click="bulk_audit"
                disabled={!@headless_configured}
                class={[
                  "px-4 py-2 text-sm font-medium rounded-lg border",
                  if(@headless_configured,
                    do: "bg-white text-indigo-700 border-indigo-300 hover:bg-indigo-50",
                    else: "bg-gray-50 text-gray-400 border-gray-200 cursor-not-allowed"
                  )
                ]}
              >
                Audit top pages
              </button>
            </div>
          </div>
          <form phx-change="update_audit_url" phx-submit="audit_url" class="mt-4 flex gap-2">
            <input
              type="text"
              name="audit_url_input"
              value={@audit_url_input}
              placeholder="https://example.com/page-to-audit"
              class="flex-1 px-3 py-2 border border-gray-300 rounded-lg text-sm"
            />
            <button
              type="submit"
              disabled={!@headless_configured}
              class={[
                "px-4 py-2 text-sm font-medium rounded-lg text-white",
                if(@headless_configured,
                  do: "bg-indigo-600 hover:bg-indigo-700",
                  else: "bg-gray-300 cursor-not-allowed"
                )
              ]}
            >
              Audit this URL
            </button>
          </form>
        </div>

        <p :if={!@can_write} class="text-xs text-gray-400 mb-6">
          Read-only — viewers can browse audits but can't trigger new ones.
        </p>

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-5 py-3 border-b border-gray-100 flex items-center justify-between">
            <h2 class="text-sm font-semibold text-gray-700">Audited pages</h2>
            <form phx-change="change_sort" class="text-xs">
              <label class="text-gray-500">Sort:</label>
              <select name="sort" class="ml-2 border border-gray-300 rounded px-2 py-1">
                <option value="score_asc" selected={@sort == :score_asc}>Score (worst first)</option>
                <option value="score_desc" selected={@sort == :score_desc}>Score (best first)</option>
                <option value="recent" selected={@sort == :recent}>Most recent audit</option>
                <option value="url" selected={@sort == :url}>URL (A-Z)</option>
              </select>
            </form>
          </div>
          <table class="min-w-full text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">URL</th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Score
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Issues
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Response
                </th>
                <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Audited
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={@audits == []}>
                <td colspan="5" class="px-5 py-6 text-center text-gray-400 text-xs">
                  No audits yet. Click "Audit top pages" or paste a URL above to start.
                </td>
              </tr>
              <%= for a <- @audits do %>
                <tr
                  phx-click="toggle_audit"
                  phx-value-id={a.id}
                  class={[
                    "cursor-pointer hover:bg-indigo-50",
                    if(@expanded_audit_id == a.id, do: "bg-indigo-50", else: "")
                  ]}
                >
                  <td class="px-5 py-2 font-mono text-xs truncate max-w-md">
                    <span class="mr-1 text-gray-400">
                      {if @expanded_audit_id == a.id, do: "▾", else: "▸"}
                    </span>
                    {a.url}
                  </td>
                  <td class="px-5 py-2 text-right">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium tabular-nums",
                      score_class(a.score, a)
                    ]}>
                      {score_display(a)}
                    </span>
                  </td>
                  <td class="px-5 py-2 text-left text-xs">
                    {render_issue_summary(a)}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_response(a.response_time_ms)}
                  </td>
                  <td class="px-5 py-2 text-right text-xs text-gray-500">
                    {format_relative(a.captured_at)}
                  </td>
                </tr>
                <tr :if={@expanded_audit_id == a.id} class="bg-gray-50">
                  <td colspan="5" class="px-5 py-4">
                    {render_audit_detail(a)}
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp avg_score([]), do: "—"

  defp avg_score(audits) do
    scores = audits |> Enum.map(& &1.score) |> Enum.reject(&is_nil/1)

    if scores == [] do
      "—"
    else
      Float.round(Enum.sum(scores) / length(scores), 1)
    end
  end

  defp critical_count(audits) do
    Enum.reduce(audits, 0, fn a, acc ->
      acc + (severity_breakdown(a) |> Map.get("critical", 0))
    end)
  end

  defp format_response(nil), do: "—"
  defp format_response(ms) when ms < 1000, do: "#{ms}ms"
  defp format_response(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_relative(nil), do: "—"

  defp format_relative(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end
end
