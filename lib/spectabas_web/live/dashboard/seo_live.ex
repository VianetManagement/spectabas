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

    if is_binary(path) and path != "" do
      scheme = if site.gdpr_mode == "off", do: "https", else: "https"
      "#{scheme}://#{site.domain |> String.replace_prefix("b.", "")}#{path}"
    else
      nil
    end
  end

  defp system_user, do: %Spectabas.Accounts.User{role: :platform_admin}

  defp load_audits(socket) do
    audits = SEO.latest_per_url(socket.assigns.site.id, order: socket.assigns.sort, limit: 200)
    assign(socket, :audits, audits)
  end

  defp score_class(nil), do: "bg-gray-100 text-gray-500"

  defp score_class(s) when is_integer(s) do
    cond do
      s >= 80 -> "bg-emerald-100 text-emerald-800"
      s >= 60 -> "bg-amber-100 text-amber-800"
      true -> "bg-rose-100 text-rose-800"
    end
  end

  defp issue_count(%{issues: %{"items" => items}}) when is_list(items), do: length(items)
  defp issue_count(_), do: 0

  defp severity_breakdown(%{issues: %{"items" => items}}) when is_list(items) do
    items
    |> Enum.frequencies_by(&Map.get(&1, "severity"))
  end

  defp severity_breakdown(_), do: %{}

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
              <tr :for={a <- @audits} class="hover:bg-indigo-50">
                <td class="px-5 py-2 font-mono text-xs truncate max-w-md">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/transitions?path=#{url_path(a.url)}"}
                    class="text-indigo-700 hover:text-indigo-900"
                  >
                    {a.url}
                  </.link>
                </td>
                <td class="px-5 py-2 text-right">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium tabular-nums",
                    score_class(a.score)
                  ]}>
                    {a.score || "—"}
                  </span>
                </td>
                <td class="px-5 py-2 text-right tabular-nums text-xs">
                  <% breakdown = severity_breakdown(a) %>
                  <span :if={Map.get(breakdown, "critical", 0) > 0} class="text-rose-700">
                    {Map.get(breakdown, "critical", 0)}c
                  </span>
                  <span :if={Map.get(breakdown, "major", 0) > 0} class="text-amber-700 ml-1">
                    {Map.get(breakdown, "major", 0)}M
                  </span>
                  <span :if={Map.get(breakdown, "minor", 0) > 0} class="text-gray-500 ml-1">
                    {Map.get(breakdown, "minor", 0)}m
                  </span>
                  <span :if={issue_count(a) == 0} class="text-emerald-700">0</span>
                </td>
                <td class="px-5 py-2 text-right tabular-nums text-xs">
                  {format_response(a.response_time_ms)}
                </td>
                <td class="px-5 py-2 text-right text-xs text-gray-500">
                  {format_relative(a.captured_at)}
                </td>
              </tr>
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

  defp url_path(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: p} when is_binary(p) -> p
      _ -> "/"
    end
  end

  defp url_path(_), do: "/"
end
