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

  @valid_tabs ~w(scrapers webhook_log calibration)

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
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
        |> assign(:webhook_result, nil)
        |> assign(:tab, "scrapers")
        |> assign(:webhook_log, [])
        |> assign(:sort_by, "score")
        |> assign(:sort_dir, "desc")
        |> assign(:calibrations, [])
        |> assign(:calibrating, false)
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
      if connected?(socket) do
        send(self(), :load_data)
        Phoenix.PubSub.subscribe(Spectabas.PubSub, "calibration:#{site.id}")
      end

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @valid_tabs, do: params["tab"], else: "scrapers"
    {:noreply, apply_tab(socket, tab)}
  end

  defp apply_tab(socket, "calibration") do
    calibrations = Spectabas.Analytics.ScraperCalibration.latest_for_site(socket.assigns.site.id)
    has_pending_job = calibration_job_running?(socket.assigns.site.id)

    socket
    |> assign(:tab, "calibration")
    |> assign(:calibrations, calibrations)
    |> assign(:calibrating, has_pending_job)
  rescue
    _ -> assign(socket, :tab, "calibration")
  end

  defp apply_tab(socket, "webhook_log") do
    log = Spectabas.Webhooks.ScraperWebhook.list_deliveries(socket.assigns.site.id)
    socket |> assign(:tab, "webhook_log") |> assign(:webhook_log, log)
  rescue
    _ -> assign(socket, :tab, "webhook_log")
  end

  defp apply_tab(socket, tab), do: assign(socket, :tab, tab)

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:calibration_done, result}, socket) do
    calibrations = Spectabas.Analytics.ScraperCalibration.latest_for_site(socket.assigns.site.id)

    socket =
      case result do
        {:ok, _cal} ->
          socket |> put_flash(:info, "AI calibration complete — review recommendations below.")

        {:error, reason} ->
          msg = if is_binary(reason), do: reason, else: inspect(reason)
          socket |> put_flash(:error, "Calibration failed: #{msg}")
      end

    {:noreply, socket |> assign(:calibrating, false) |> assign(:calibrations, calibrations)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    site_id = socket.assigns.site.id

    path =
      if tab == "scrapers",
        do: "/sites/#{site_id}/scrapers",
        else: "/sites/#{site_id}/scrapers?tab=#{tab}"

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("run_calibration", _params, socket) do
    %{"site_id" => socket.assigns.site.id}
    |> Spectabas.Workers.ScraperCalibrationWorker.new()
    |> Oban.insert()

    {:noreply, assign(socket, :calibrating, true)}
  end

  def handle_event("approve_calibration", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    Spectabas.Analytics.ScraperCalibration.approve_calibration(id)
    site = Sites.get_site!(socket.assigns.site.id)
    calibrations = Spectabas.Analytics.ScraperCalibration.latest_for_site(site.id)

    {:noreply,
     socket
     |> assign(:site, site)
     |> assign(:calibrations, calibrations)
     |> put_flash(:info, "Calibration approved — weight overrides applied.")}
  end

  def handle_event("reject_calibration", %{"id" => id_str}, socket) do
    {id, _} = Integer.parse(id_str)
    Spectabas.Analytics.ScraperCalibration.reject_calibration(id)
    calibrations = Spectabas.Analytics.ScraperCalibration.latest_for_site(socket.assigns.site.id)
    {:noreply, socket |> assign(:calibrations, calibrations)}
  end

  def handle_event("clear_overrides", _params, socket) do
    {:ok, site} = Sites.update_site(socket.assigns.site, %{"scraper_weight_overrides" => nil})

    {:noreply,
     socket
     |> assign(:site, site)
     |> put_flash(:info, "Weight overrides cleared — using defaults.")}
  end

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

  def handle_event("sort_scrapers", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_by == field do
        if socket.assigns.sort_dir == "asc", do: "desc", else: "asc"
      else
        "desc"
      end

    {:noreply, socket |> assign(:sort_by, field) |> assign(:sort_dir, dir)}
  end

  def handle_event("open_visitor", %{"visitor_id" => vid}, socket) do
    v = Enum.find(socket.assigns.candidates || [], &(&1["visitor_id"] == vid))
    {:noreply, assign(socket, :modal_visitor, v)}
  end

  def handle_event("close_visitor", _params, socket) do
    {:noreply, socket |> assign(:modal_visitor, nil) |> assign(:webhook_result, nil)}
  end

  def handle_event("send_webhook", %{"visitor_id" => visitor_id}, socket) do
    site = socket.assigns.site
    v = socket.assigns.modal_visitor

    case Spectabas.Repo.get_by(Spectabas.Visitors.Visitor, id: visitor_id, site_id: site.id) do
      nil ->
        {:noreply, assign(socket, :webhook_result, {:error, %{reason: "Visitor not found"}})}

      visitor ->
        score_result = %{score: v["score"], signals: v["signals"] || []}
        pageviews = v["session_pageviews"] || 0

        case Spectabas.Webhooks.ScraperWebhook.send_flag(site, visitor, score_result, pageviews) do
          {:ok, detail} ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)

            visitor
            |> Spectabas.Visitors.Visitor.changeset(%{
              scraper_webhook_sent_at: now,
              scraper_webhook_score: v["score"]
            })
            |> Spectabas.Repo.update()

            log = Spectabas.Webhooks.ScraperWebhook.list_deliveries(site.id)

            {:noreply,
             socket |> assign(:webhook_result, {:ok, detail}) |> assign(:webhook_log, log)}

          {:error, detail} ->
            log = Spectabas.Webhooks.ScraperWebhook.list_deliveries(site.id)

            {:noreply,
             socket |> assign(:webhook_result, {:error, detail}) |> assign(:webhook_log, log)}
        end
    end
  end

  def handle_event("deactivate_webhook", %{"visitor_id" => visitor_id}, socket) do
    site = socket.assigns.site

    case Spectabas.Repo.get_by(Spectabas.Visitors.Visitor, id: visitor_id, site_id: site.id) do
      nil ->
        {:noreply, assign(socket, :webhook_result, {:error, %{reason: "Visitor not found"}})}

      visitor ->
        case Spectabas.Webhooks.ScraperWebhook.send_deactivate(site, visitor) do
          {:ok, detail} ->
            visitor
            |> Spectabas.Visitors.Visitor.changeset(%{
              scraper_webhook_sent_at: nil,
              scraper_webhook_score: nil
            })
            |> Spectabas.Repo.update()

            log = Spectabas.Webhooks.ScraperWebhook.list_deliveries(site.id)

            {:noreply,
             socket |> assign(:webhook_result, {:ok, detail}) |> assign(:webhook_log, log)}

          {:error, detail} ->
            log = Spectabas.Webhooks.ScraperWebhook.list_deliveries(site.id)

            {:noreply,
             socket |> assign(:webhook_result, {:error, detail}) |> assign(:webhook_log, log)}
        end
    end
  end

  defp calibration_job_running?(site_id) do
    import Ecto.Query

    Oban.Job
    |> where([j], j.worker == "Spectabas.Workers.ScraperCalibrationWorker")
    |> where([j], j.state in ["available", "executing", "scheduled"])
    |> where([j], fragment("?->>'site_id' = ?", j.args, ^to_string(site_id)))
    |> Spectabas.ObanRepo.exists?()
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
        <div class="flex items-center justify-between flex-wrap gap-3 mb-6">
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

        <%!-- Tab navigation --%>
        <nav class="flex gap-1 bg-gray-100 rounded-lg p-1 mb-6 w-fit">
          <button
            :for={
              {id, label} <- [
                {"scrapers", "Detection"},
                {"webhook_log", "Webhook Log"},
                {"calibration", "Calibration"}
              ]
            }
            phx-click="switch_tab"
            phx-value-tab={id}
            class={[
              "px-4 py-1.5 text-sm font-medium rounded-md",
              if(@tab == id,
                do: "bg-white shadow text-gray-900",
                else: "text-gray-600 hover:text-gray-900"
              )
            ]}
          >
            {label}
          </button>
        </nav>

        <div :if={@tab == "scrapers"}>
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
                  <th
                    class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-indigo-600"
                    phx-click="sort_scrapers"
                    phx-value-field="score"
                  >
                    Score <.sort_indicator sort_by={@sort_by} sort_dir={@sort_dir} field="score" />
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Signals
                  </th>
                  <th
                    class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-indigo-600"
                    phx-click="sort_scrapers"
                    phx-value-field="pageviews"
                  >
                    Pageviews
                    <.sort_indicator sort_by={@sort_by} sort_dir={@sort_dir} field="pageviews" />
                  </th>
                  <th
                    class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-indigo-600"
                    phx-click="sort_scrapers"
                    phx-value-field="ips"
                  >
                    IPs <.sort_indicator sort_by={@sort_by} sort_dir={@sort_dir} field="ips" />
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                    Network
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                    Location
                  </th>
                  <th
                    class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase cursor-pointer hover:text-indigo-600"
                    phx-click="sort_scrapers"
                    phx-value-field="last_seen"
                  >
                    Last Seen
                    <.sort_indicator sort_by={@sort_by} sort_dir={@sort_dir} field="last_seen" />
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
                  :for={c <- sort_candidates(@candidates, @sort_by, @sort_dir)}
                  class="hover:bg-amber-50 cursor-pointer"
                  phx-click="open_visitor"
                  phx-value-visitor_id={c["visitor_id"]}
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
                  <td class="px-4 py-3 text-xs text-gray-600 truncate max-w-xs hidden md:table-cell">
                    {blank_to_dash(c["asn"])}
                  </td>
                  <td class="px-4 py-3 text-xs text-gray-600 hidden md:table-cell">
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
                  class="shrink-0 ml-4 text-gray-400 hover:text-gray-700 text-2xl leading-none p-3"
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

                <div
                  :if={@site.scraper_webhook_enabled && @site.scraper_webhook_url}
                  class="pt-3 border-t border-gray-200"
                >
                  <div class="flex items-center gap-2">
                    <button
                      type="button"
                      phx-click="send_webhook"
                      phx-value-visitor_id={v["visitor_id"]}
                      class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-white bg-red-600 hover:bg-red-700 shadow-sm"
                    >
                      Send webhook
                    </button>
                    <button
                      type="button"
                      phx-click="deactivate_webhook"
                      phx-value-visitor_id={v["visitor_id"]}
                      class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-gray-700 bg-gray-100 hover:bg-gray-200 border border-gray-300"
                    >
                      Mark as not scraper
                    </button>
                    <span
                      :if={@webhook_result}
                      class={[
                        "text-xs ml-2 font-medium",
                        if(elem(@webhook_result, 0) == :ok,
                          do: "text-green-600",
                          else: "text-red-600"
                        )
                      ]}
                    >
                      {if elem(@webhook_result, 0) == :ok,
                        do: "Sent! (#{elem(@webhook_result, 1).status})",
                        else: "Failed"}
                    </span>
                  </div>

                  <%= if @webhook_result do %>
                    <% {status, detail} = @webhook_result %>
                    <div class="mt-3 space-y-2">
                      <div>
                        <div class="text-xs font-semibold text-gray-500 uppercase mb-1">
                          Request →
                          <span class="font-mono font-normal text-gray-600">
                            {detail[:url]}
                          </span>
                        </div>
                        <div class="bg-gray-50 border border-gray-200 rounded p-2 text-xs font-mono text-gray-800 max-h-40 overflow-y-auto whitespace-pre-wrap break-all">
                          {Jason.encode!(detail[:request], pretty: true)}
                        </div>
                      </div>
                      <div>
                        <div class="text-xs font-semibold text-gray-500 uppercase mb-1">
                          Response
                          <span
                            :if={detail[:status]}
                            class={[
                              "ml-1 font-mono font-normal",
                              if(status == :ok, do: "text-green-600", else: "text-red-600")
                            ]}
                          >
                            HTTP {detail[:status]}
                          </span>
                          <span :if={detail[:reason]} class="ml-1 font-mono font-normal text-red-600">
                            {inspect(detail[:reason])}
                          </span>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>

                <div class="pt-3 border-t border-gray-200 flex items-center justify-between">
                  <div class="text-xs text-gray-500">
                    Use this visitor_id in your own API or middleware to drive tarpits, data
                    poisoning, honeypots, or other countermeasures.
                  </div>
                  <a
                    href={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                    target="_blank"
                    class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shrink-0 ml-3"
                  >
                    Full visitor profile &nearr;
                  </a>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Webhook Log Tab --%>
        <div :if={@tab == "webhook_log"}>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-6 py-4 border-b border-gray-200">
              <h2 class="text-lg font-semibold text-gray-900">Webhook Delivery Log</h2>
              <p class="text-xs text-gray-500 mt-0.5">
                Last 50 webhook deliveries (30-day retention)
              </p>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Time
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Type
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Visitor
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Score
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Signals
                  </th>
                  <th class="px-6 py-3 text-center text-xs font-medium text-gray-500 uppercase">
                    Status
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase hidden sm:table-cell">
                    Detail
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-200">
                <tr :if={@webhook_log == []}>
                  <td colspan="7" class="px-6 py-8 text-center text-gray-500 text-sm">
                    No webhook deliveries yet. Deliveries are logged when the Oban worker flags a scraper or when you manually send/deactivate from the Detection tab.
                  </td>
                </tr>
                <tr :for={d <- @webhook_log} class="hover:bg-gray-50">
                  <td class="px-6 py-3 text-xs text-gray-500 whitespace-nowrap">
                    {Calendar.strftime(d.inserted_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td class="px-6 py-3 text-sm">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      if(d.event_type == "flag",
                        do: "bg-red-100 text-red-800",
                        else: "bg-green-100 text-green-800"
                      )
                    ]}>
                      {d.event_type}
                    </span>
                  </td>
                  <td class="px-6 py-3 text-sm">
                    <a
                      :if={d.visitor_id}
                      href={~p"/dashboard/sites/#{@site.id}/visitors/#{d.visitor_id}"}
                      target="_blank"
                      class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                    >
                      {String.slice(to_string(d.visitor_id), 0, 12)}... &nearr;
                    </a>
                  </td>
                  <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {d.score || "-"}
                  </td>
                  <td class="px-6 py-3">
                    <div class="flex flex-wrap gap-1">
                      <span
                        :for={sig <- d.signals || []}
                        class="inline-flex items-center px-1.5 py-0 rounded text-[10px] font-medium bg-gray-100 text-gray-600"
                      >
                        {sig}
                      </span>
                    </div>
                  </td>
                  <td class="px-6 py-3 text-center">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      if(d.success,
                        do: "bg-green-100 text-green-800",
                        else: "bg-red-100 text-red-800"
                      )
                    ]}>
                      {if d.success, do: "OK", else: "Failed"}
                    </span>
                  </td>
                  <td class="px-6 py-3 text-xs text-gray-500 hidden sm:table-cell">
                    <%= cond do %>
                      <% d.success && d.http_status -> %>
                        <span class="font-mono">HTTP {d.http_status}</span>
                      <% d.error_message -> %>
                        <span class="text-red-600">{String.slice(d.error_message, 0, 60)}</span>
                      <% d.http_status -> %>
                        <span class="font-mono text-red-600">HTTP {d.http_status}</span>
                      <% true -> %>
                        -
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Calibration Tab --%>
        <div :if={@tab == "calibration"}>
          <%!-- Current overrides --%>
          <div class="bg-white rounded-lg shadow mb-6">
            <div class="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
              <div>
                <h2 class="text-lg font-semibold text-gray-900">AI Score Calibration</h2>
                <p class="text-xs text-gray-500 mt-0.5">
                  Analyze your site's visitor behavior and get AI-recommended weight adjustments.
                </p>
              </div>
              <div class="flex items-center gap-2">
                <button
                  :if={@site.scraper_weight_overrides}
                  phx-click="clear_overrides"
                  data-confirm="Reset to default weights? This removes all per-site overrides."
                  class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-gray-700 bg-gray-100 hover:bg-gray-200 border border-gray-300"
                >
                  Reset to Defaults
                </button>
                <button
                  phx-click="run_calibration"
                  disabled={@calibrating}
                  class={[
                    "inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white shadow-sm",
                    if(@calibrating,
                      do: "bg-indigo-400 cursor-wait",
                      else: "bg-indigo-600 hover:bg-indigo-700"
                    )
                  ]}
                >
                  {if @calibrating, do: "Analyzing...", else: "Run AI Calibration"}
                </button>
              </div>
            </div>

            <%!-- Active weights display --%>
            <div class="px-6 py-4">
              <h3 class="text-sm font-semibold text-gray-700 mb-3">
                {if @site.scraper_weight_overrides,
                  do: "Active Per-Site Weights",
                  else: "Default Weights (no overrides)"}
              </h3>
              <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
                <div
                  :for={{key, default_val} <- Spectabas.Analytics.ScraperDetector.default_weights()}
                  class="bg-gray-50 rounded-lg p-3"
                >
                  <div class="text-xs text-gray-500">{key}</div>
                  <div class="text-lg font-bold text-gray-900 mt-0.5">
                    +{active_weight(@site.scraper_weight_overrides, key, default_val)}
                  </div>
                  <div
                    :if={override_differs?(@site.scraper_weight_overrides, key, default_val)}
                    class="text-[10px] text-indigo-600 mt-0.5"
                  >
                    default: +{default_val}
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Calibration history --%>
          <div :for={cal <- @calibrations} class="bg-white rounded-lg shadow mb-4">
            <div class="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
              <div>
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium mr-2",
                  case cal.status do
                    "pending" -> "bg-amber-100 text-amber-800"
                    "approved" -> "bg-green-100 text-green-800"
                    "rejected" -> "bg-gray-100 text-gray-500"
                  end
                ]}>
                  {cal.status}
                </span>
                <span class="text-sm text-gray-500">
                  {Calendar.strftime(cal.inserted_at, "%b %d, %Y %H:%M UTC")}
                </span>
                <span :if={cal.ai_provider} class="text-xs text-gray-400 ml-2">
                  via {cal.ai_provider}
                </span>
              </div>
              <div :if={cal.status == "pending"} class="flex gap-2">
                <button
                  phx-click="approve_calibration"
                  phx-value-id={cal.id}
                  class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-white bg-green-600 hover:bg-green-700"
                >
                  Approve
                </button>
                <button
                  phx-click="reject_calibration"
                  phx-value-id={cal.id}
                  class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-gray-700 bg-gray-100 hover:bg-gray-200 border border-gray-300"
                >
                  Reject
                </button>
              </div>
            </div>

            <div class="px-6 py-4 space-y-4">
              <%!-- Baseline stats --%>
              <div :if={cal.baseline}>
                <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">
                  Site Baseline (30 days)
                </h4>
                <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
                  <div>
                    <span class="text-gray-500">Visitors:</span>
                    <span class="font-medium ml-1">
                      {format_number(cal.baseline["total_visitors"] || 0)}
                    </span>
                  </div>
                  <div>
                    <span class="text-gray-500">p95 pages:</span>
                    <span class="font-medium ml-1">
                      {get_in(cal.baseline, ["pageview_distribution", "p95"]) || "?"}
                    </span>
                  </div>
                  <div>
                    <span class="text-gray-500">DC visitors:</span>
                    <span class="font-medium ml-1">
                      {get_in(cal.baseline, ["network", "datacenter"]) || "?"}
                    </span>
                  </div>
                  <div>
                    <span class="text-gray-500">VPN visitors:</span>
                    <span class="font-medium ml-1">
                      {get_in(cal.baseline, ["network", "vpn"]) || "?"}
                    </span>
                  </div>
                </div>
              </div>

              <%!-- AI recommendations --%>
              <div :if={cal.recommendations}>
                <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">
                  Recommended Weights
                </h4>
                <%= if cal.recommendations["weights"] do %>
                  <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2">
                    <div
                      :for={{key, val} <- cal.recommendations["weights"]}
                      class="bg-gray-50 rounded p-2"
                    >
                      <div class="text-xs text-gray-500">{key}</div>
                      <div class="text-sm font-bold text-gray-900">+{val}</div>
                    </div>
                  </div>
                <% end %>

                <div
                  :if={cal.recommendations["reasoning"]}
                  class="mt-3 text-sm text-gray-700 bg-blue-50 border border-blue-100 rounded-lg p-3"
                >
                  <span class="font-medium text-blue-800">AI reasoning:</span>
                  {cal.recommendations["reasoning"]}
                </div>

                <div class="flex gap-4 mt-2 text-xs text-gray-500">
                  <span :if={cal.recommendations["confidence"]}>
                    Confidence: <span class="font-medium">{cal.recommendations["confidence"]}</span>
                  </span>
                  <span :if={cal.recommendations["warnings"]}>
                    Warnings: <span class="text-amber-600">{cal.recommendations["warnings"]}</span>
                  </span>
                </div>

                <div
                  :if={cal.recommendations["error"]}
                  class="mt-2 text-sm text-red-600 bg-red-50 rounded-lg p-3"
                >
                  {cal.recommendations["error"]}
                  <div :if={cal.recommendations["raw"]} class="text-xs font-mono mt-1 text-red-500">
                    {cal.recommendations["raw"]}
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div
            :if={@calibrations == []}
            class="bg-white rounded-lg shadow px-6 py-8 text-center text-gray-500 text-sm"
          >
            No calibrations yet. Click "Run AI Calibration" to analyze your site's visitor behavior and get weight recommendations.
          </div>
        </div>
      </div>
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

  defp active_weight(nil, _key, default), do: default

  defp active_weight(overrides, key, default) when is_map(overrides) do
    key_str = to_string(key)
    Map.get(overrides, key_str, default)
  end

  defp active_weight(_, _, default), do: default

  defp override_differs?(nil, _key, _default), do: false

  defp override_differs?(overrides, key, default) when is_map(overrides) do
    key_str = to_string(key)
    Map.has_key?(overrides, key_str) and Map.get(overrides, key_str) != default
  end

  defp override_differs?(_, _, _), do: false

  defp sort_candidates(candidates, sort_by, sort_dir) do
    sorted =
      Enum.sort_by(candidates, fn c ->
        case sort_by do
          "score" -> to_num(c["score"])
          "pageviews" -> to_num(c["session_pageviews"])
          "ips" -> to_num(c["visitor_ip_count"])
          "last_seen" -> c["last_seen"] || ""
          _ -> to_num(c["score"])
        end
      end)

    if sort_dir == "desc", do: Enum.reverse(sorted), else: sorted
  end

  defp sort_indicator(assigns) do
    ~H"""
    <span :if={@sort_by == @field} class="ml-0.5 text-indigo-500">
      {if @sort_dir == "asc", do: "↑", else: "↓"}
    </span>
    """
  end
end
