defmodule SpectabasWeb.Dashboard.ScrapersLive do
  @moduledoc """
  Scraper detection dashboard. Shows visitors scoring 60+ on the
  ScraperDetector, grouped by verdict (:suspicious 60-84, :certain 85+).
  Site owners configure which URL prefixes count as "content" (for the
  systematic-crawl signal) in Settings → Scraper Detection.
  """

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  alias Spectabas.Analytics.ScraperDetector
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
      socket =
        socket
        |> assign(:page_title, "Scrapers - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:min_score, 60)
        |> assign(:modal_visitor, nil)
        |> assign(:loading, true)
        |> assign(:candidates, [])
        |> assign(:summary, %{
          total: 0,
          suspicious: 0,
          certain: 0,
          datacenter: 0,
          spoofed: 0,
          rotating: 0
        })

      # Load asynchronously — the ClickHouse query can take 10-30s on large
      # sites. Loading in mount would timeout the LiveView and cause infinite
      # reconnect loops.
      if connected?(socket), do: send(self(), :load_data)

      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("change_min_score", %{"min_score" => v}, socket) do
    min =
      case Integer.parse(v || "") do
        {n, _} when n >= 0 and n <= 100 -> n
        _ -> 60
      end

    send(self(), :load_data)
    {:noreply, socket |> assign(:min_score, min) |> assign(:loading, true)}
  end

  def handle_event("open_visitor", %{"idx" => idx_str}, socket) do
    case Integer.parse(idx_str) do
      {idx, _} ->
        v = Enum.at(socket.assigns.candidates || [], idx)
        {:noreply, assign(socket, :modal_visitor, v)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_visitor", _params, socket) do
    {:noreply, assign(socket, :modal_visitor, nil)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, min_score: min_score} = socket.assigns
    period = range_to_period(range)

    # Single query — summary is computed from the same result set to avoid
    # running the expensive aggregation twice.
    candidates =
      case Analytics.scraper_candidates(site, user, period, min_score: min_score, limit: 100) do
        {:ok, rows} -> rows
        _ -> []
      end

    summary = summarize_candidates(candidates)

    socket
    |> assign(:summary, summary)
    |> assign(:candidates, candidates)
    |> assign(:loading, false)
  end

  defp summarize_candidates(candidates) do
    %{
      total: length(candidates),
      suspicious: Enum.count(candidates, &(&1["verdict"] == :suspicious)),
      certain: Enum.count(candidates, &(&1["verdict"] == :certain)),
      datacenter: Enum.count(candidates, &(:datacenter_asn in (&1["signals"] || []))),
      spoofed: Enum.count(candidates, &(:spoofed_mobile_ua in (&1["signals"] || []))),
      rotating: Enum.count(candidates, &(:ip_rotation in (&1["signals"] || [])))
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Scrapers"
      page_description="Visitors flagged as likely scrapers via weighted signals. Click a row to see full details."
      active="scrapers"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Scraper Detection</h1>
            <p class="text-sm text-gray-500 mt-1">
              Visitors scoring {@min_score}+ on the ScraperDetector weighted-signal model.
            </p>
          </div>
          <div class="flex items-center gap-3">
            <form phx-change="change_min_score">
              <select
                name="min_score"
                class="text-sm rounded-md border-gray-300 py-1.5 pr-8"
              >
                <option value="60" selected={@min_score == 60}>Score ≥ 60 (suspicious)</option>
                <option value="85" selected={@min_score == 85}>Score ≥ 85 (certain)</option>
                <option value="40" selected={@min_score == 40}>Score ≥ 40 (broader)</option>
              </select>
            </form>
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
          </div>
        </div>

        <%!-- Configuration notice --%>
        <%= if Enum.empty?(@site.scraper_content_prefixes || []) do %>
          <div class="bg-amber-50 border border-amber-200 text-amber-900 rounded-lg p-4 mb-6 text-sm">
            <span class="font-semibold">Configure content prefixes</span>
            to enable the
            systematic-crawl signal. <.link
              navigate={~p"/dashboard/sites/#{@site.id}/settings"}
              class="text-amber-900 underline hover:text-amber-700"
            >
              Site Settings → Scraper Detection
            </.link>. Without this, detection still works but misses scrapers
            who systematically crawl content URLs (e.g. /listings/*).
          </div>
        <% end %>

        <%!-- Summary cards --%>
        <div class="grid grid-cols-2 md:grid-cols-6 gap-4 mb-8">
          <div class="bg-white rounded-lg shadow p-4 border-t-4 border-red-500">
            <div class="text-xs font-medium text-gray-500 uppercase">Certain</div>
            <div class="text-2xl font-bold text-red-700 mt-1">{@summary.certain}</div>
            <div class="text-xs text-gray-500 mt-0.5">score ≥ 85</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4 border-t-4 border-amber-500">
            <div class="text-xs font-medium text-gray-500 uppercase">Suspicious</div>
            <div class="text-2xl font-bold text-amber-600 mt-1">{@summary.suspicious}</div>
            <div class="text-xs text-gray-500 mt-0.5">score 60–84</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs font-medium text-gray-500 uppercase">Datacenter</div>
            <div class="text-2xl font-bold text-gray-900 mt-1">{@summary.datacenter}</div>
            <div class="text-xs text-gray-500 mt-0.5">flagged ASN</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs font-medium text-gray-500 uppercase">Spoofed UA</div>
            <div class="text-2xl font-bold text-gray-900 mt-1">{@summary.spoofed}</div>
            <div class="text-xs text-gray-500 mt-0.5">mobile UA + DC IP</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs font-medium text-gray-500 uppercase">IP Rotation</div>
            <div class="text-2xl font-bold text-gray-900 mt-1">{@summary.rotating}</div>
            <div class="text-xs text-gray-500 mt-0.5">same cookie, 3+ IPs</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <div class="text-xs font-medium text-gray-500 uppercase">Total Flagged</div>
            <div class="text-2xl font-bold text-gray-900 mt-1">{@summary.total}</div>
            <div class="text-xs text-gray-500 mt-0.5">all scores &gt; 0</div>
          </div>
        </div>

        <%= if @loading do %>
          <div class="bg-white rounded-lg shadow p-12 text-center mb-8">
            <div class="inline-flex items-center gap-3 text-gray-600">
              <svg
                class="animate-spin h-5 w-5 text-indigo-600"
                viewBox="0 0 24 24"
                fill="none"
              >
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
              <span class="text-sm">
                Scanning visitors for scraper signals... This can take 10-30 seconds on large sites.
              </span>
            </div>
          </div>
        <% end %>

        <%!-- Candidates table --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Visitor
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Score
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Signals
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Pageviews
                </th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  IPs
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Network
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Location
                </th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Last Seen
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={@candidates == []}>
                <td colspan="8" class="px-4 py-12 text-center text-gray-500">
                  No scraper candidates in this range. Either your site is clean, or you
                  may need to configure content path prefixes for the systematic-crawl
                  signal to fire (<.link
                    navigate={~p"/dashboard/sites/#{@site.id}/settings"}
                    class="text-indigo-600 underline"
                  >Settings</.link>).
                </td>
              </tr>
              <tr
                :for={{c, idx} <- Enum.with_index(@candidates)}
                class="hover:bg-amber-50 cursor-pointer"
                phx-click="open_visitor"
                phx-value-idx={idx}
              >
                <td class="px-4 py-3 text-sm">
                  <span class="font-mono text-xs text-indigo-700">
                    {String.slice(c["visitor_id"] || "", 0, 12)}...
                  </span>
                </td>
                <td class="px-4 py-3">
                  <span class={[
                    "inline-flex items-center justify-center w-10 h-6 rounded text-xs font-bold",
                    score_color(to_num(c["score"]))
                  ]}>
                    {c["score"]}
                  </span>
                </td>
                <td class="px-4 py-3">
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={sig <- c["signals"] || []}
                      class={[
                        "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium",
                        signal_color(sig)
                      ]}
                    >
                      {signal_label(sig)}
                    </span>
                  </div>
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(c["session_pageviews"]))}
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {to_num(c["visitor_ip_count"])}
                </td>
                <td class="px-4 py-3 text-xs text-gray-600 truncate max-w-xs">
                  {blank_to_dash(c["asn"])}
                </td>
                <td class="px-4 py-3 text-xs text-gray-600">
                  {[c["city"], c["country"]]
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(", ")}
                </td>
                <td class="px-4 py-3 text-xs text-gray-500 whitespace-nowrap">
                  {c["last_seen"]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Visitor detail modal --%>
      <%= if @modal_visitor do %>
        <% v = @modal_visitor %>
        <div class="fixed inset-0 bg-gray-900/50 z-40" phx-click="close_visitor"></div>
        <div class="fixed left-1/2 -translate-x-1/2 top-10 bottom-10 z-50 w-[calc(100%-2rem)] max-w-3xl bg-white rounded-lg shadow-2xl overflow-y-auto">
          <div class="sticky top-0 bg-white px-6 py-4 border-b border-gray-200 flex items-start justify-between rounded-t-lg">
            <div>
              <h3 class="text-lg font-semibold text-gray-900">Scraper Detail</h3>
              <p class="text-xs text-gray-500 mt-0.5 font-mono">{v["visitor_id"]}</p>
            </div>
            <button
              type="button"
              phx-click="close_visitor"
              class="shrink-0 ml-4 text-gray-400 hover:text-gray-700 text-2xl leading-none px-2"
              aria-label="Close"
            >
              &times;
            </button>
          </div>

          <div class="px-6 py-4 space-y-5">
            <div class="flex items-center gap-3">
              <span class={[
                "inline-flex items-center px-3 py-1 rounded-full text-sm font-bold",
                score_color(to_num(v["score"]))
              ]}>
                Score {v["score"]}
              </span>
              <span class="text-sm font-medium text-gray-700">
                Verdict: {verdict_label(v["verdict"])}
              </span>
            </div>

            <div>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">
                Triggered Signals
              </h4>
              <div class="flex flex-wrap gap-2">
                <span
                  :for={sig <- v["signals"] || []}
                  class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    signal_color(sig)
                  ]}
                  title={signal_explanation(sig)}
                >
                  {signal_label(sig)}
                </span>
                <span :if={(v["signals"] || []) == []} class="text-sm text-gray-500 italic">
                  No signals triggered.
                </span>
              </div>
            </div>

            <div class="grid grid-cols-2 sm:grid-cols-3 gap-3 text-sm">
              <div>
                <div class="text-xs text-gray-500">Pageviews</div>
                <div class="font-semibold text-gray-900">
                  {format_number(to_num(v["session_pageviews"]))}
                </div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Unique IPs</div>
                <div class="font-semibold text-gray-900">{to_num(v["visitor_ip_count"])}</div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Screen</div>
                <div class="text-gray-800">{blank_to_dash(v["screen_resolution"])}</div>
              </div>
              <div>
                <div class="text-xs text-gray-500">First Seen</div>
                <div class="text-gray-800">{blank_to_dash(v["first_seen"])}</div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Last Seen</div>
                <div class="text-gray-800">{blank_to_dash(v["last_seen"])}</div>
              </div>
              <div>
                <div class="text-xs text-gray-500">Location</div>
                <div class="text-gray-800">
                  {[v["city"], v["country"]]
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(", ")
                  |> blank_to_dash()}
                </div>
              </div>
              <div class="col-span-2 sm:col-span-3">
                <div class="text-xs text-gray-500">Referrer</div>
                <div class="text-gray-800">{blank_to_dash(v["referrer"])}</div>
              </div>
              <div class="col-span-2 sm:col-span-3">
                <div class="text-xs text-gray-500">ASN / Network</div>
                <div class="text-gray-800">{blank_to_dash(v["asn"])}</div>
              </div>
            </div>

            <div>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-1">User Agent</h4>
              <div class="bg-gray-50 border border-gray-200 rounded p-3 text-xs font-mono text-gray-800 break-all">
                {blank_to_dash(v["user_agent"])}
              </div>
            </div>

            <div>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">
                Recent Page Paths
                <span class="text-gray-400 font-normal">
                  ({length(List.wrap(v["page_paths"]))} total, showing up to 20)
                </span>
              </h4>
              <%= if List.wrap(v["page_paths"]) == [] do %>
                <p class="text-sm text-gray-500 italic">No pageviews captured.</p>
              <% else %>
                <div class="bg-gray-50 border border-gray-200 rounded p-3 text-xs font-mono space-y-0.5 max-h-64 overflow-y-auto">
                  <div
                    :for={path <- Enum.take(List.wrap(v["page_paths"]), 20)}
                    class="text-indigo-700 truncate"
                  >
                    {path}
                  </div>
                </div>
              <% end %>
            </div>

            <div class="pt-3 border-t border-gray-200 flex items-center justify-between">
              <div class="text-xs text-gray-500">
                Use this visitor_id in your own API or middleware to drive tarpits, data
                poisoning, honeypots, or other countermeasures.
              </div>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 shrink-0 ml-3"
              >
                Full visitor profile &rarr;
              </.link>
            </div>
          </div>
        </div>
      <% end %>
    </.dashboard_layout>
    """
  end

  # ---------------- Helpers ----------------

  defp score_color(s) when is_integer(s) and s >= 85, do: "bg-red-100 text-red-800"
  defp score_color(s) when is_integer(s) and s >= 60, do: "bg-amber-100 text-amber-800"
  defp score_color(s) when is_integer(s) and s >= 40, do: "bg-yellow-50 text-yellow-700"
  defp score_color(_), do: "bg-gray-100 text-gray-700"

  defp signal_color(:datacenter_asn), do: "bg-red-50 text-red-700"
  defp signal_color(:spoofed_mobile_ua), do: "bg-red-50 text-red-700"
  defp signal_color(:ip_rotation), do: "bg-red-50 text-red-700"
  defp signal_color(:very_high_pageviews), do: "bg-amber-50 text-amber-700"
  defp signal_color(:high_pageviews), do: "bg-amber-50 text-amber-700"
  defp signal_color(:systematic_crawl), do: "bg-amber-50 text-amber-700"
  defp signal_color(:robotic_timing), do: "bg-amber-50 text-amber-700"
  defp signal_color(:no_referrer), do: "bg-gray-100 text-gray-700"
  defp signal_color(:suspicious_resolution), do: "bg-gray-100 text-gray-700"
  defp signal_color(_), do: "bg-gray-100 text-gray-700"

  defp signal_label(:datacenter_asn), do: "Datacenter ASN"
  defp signal_label(:spoofed_mobile_ua), do: "Spoofed Mobile UA"
  defp signal_label(:ip_rotation), do: "IP Rotation"
  defp signal_label(:very_high_pageviews), do: "200+ Pageviews"
  defp signal_label(:high_pageviews), do: "50+ Pageviews"
  defp signal_label(:systematic_crawl), do: "Systematic Crawl"
  defp signal_label(:robotic_timing), do: "Robotic Timing"
  defp signal_label(:no_referrer), do: "No Referrer"
  defp signal_label(:suspicious_resolution), do: "Emulator Resolution"
  defp signal_label(sig), do: to_string(sig)

  defp signal_explanation(:datacenter_asn),
    do: "Visitor is on a known datacenter/hosting ASN (OVH, AWS, Hetzner, etc)."

  defp signal_explanation(:spoofed_mobile_ua),
    do: "Mobile user agent coming from a datacenter IP — almost always a spoofed UA string."

  defp signal_explanation(:ip_rotation),
    do:
      "Same cookie/visitor_id seen from 3+ distinct IPs. Residential users don't rotate like this."

  defp signal_explanation(:very_high_pageviews),
    do: "Session has 200+ pageviews. Humans almost never exceed this."

  defp signal_explanation(:high_pageviews),
    do: "Session has 50+ pageviews — heavy usage, possibly automated."

  defp signal_explanation(:systematic_crawl),
    do:
      ">80% of page paths match this site's content prefixes — consistent with systematic content scraping."

  defp signal_explanation(:robotic_timing),
    do: "Standard deviation of request intervals is under 300ms — evenly paced, programmatic."

  defp signal_explanation(:no_referrer), do: "Session has no referrer — direct entry to content."

  defp signal_explanation(:suspicious_resolution),
    do:
      "Screen resolution matches a known headless browser or emulator default (#{Enum.join(ScraperDetector.suspicious_resolutions(), ", ")})."

  defp signal_explanation(_), do: ""

  defp verdict_label(:certain),
    do: "Near-certain scraper (score ≥ #{ScraperDetector.score_certain()})"

  defp verdict_label(:suspicious),
    do: "Suspicious (score ≥ #{ScraperDetector.score_suspicious()})"

  defp verdict_label(:normal), do: "Normal"
  defp verdict_label(_), do: "—"
end
