defmodule SpectabasWeb.Dashboard.LogsLive do
  @moduledoc """
  Server logs dashboard at /dashboard/sites/:id/logs. Reads from the
  ClickHouse `server_logs` table populated by either the Render Logs
  API poller (`Workers.RenderLogPoller`, primary path), the HTTPS
  `POST /c/logs` endpoint (advanced shippers), or the env-gated TLS
  syslog listener.

  Two tabs:
    * Recent — newest-first paginated stream with filter bar
    * Errors — grouped by `error_fingerprint`, click a row to expand
      and see the most recent instances

  Filter bar drives both tabs: time range (1h / 24h / 7d / 30d
  clamped to site retention), level dropdown, service dropdown,
  message search.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites}
  alias Spectabas.Logs.Analytics
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Logs - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:tab, "recent")
        |> assign(:range, "24h")
        |> assign(:level, "all")
        |> assign(:service, "all")
        |> assign(:q, "")
        |> assign(:offset, 0)
        |> assign(:expanded_fingerprint, nil)
        |> assign(:expanded_logs, [])
        |> assign(:summary, %{total: 0, errors: 0, warnings: 0, services: 0, error_groups: 0})
        |> assign(:rows, [])
        |> assign(:groups, [])
        |> assign(:services, [])
        |> assign(:chart_data, %{labels: [], info: [], warning: [], error: [], critical: []})
        |> assign(:chart_key, System.unique_integer([:positive]))
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) when tab in ["recent", "errors"] do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:offset, 0)
     |> assign(:expanded_fingerprint, nil)
     |> assign(:loading, true)}
  end

  def handle_event("change_range", %{"range" => range}, socket)
      when range in ["1h", "24h", "7d", "30d"] do
    send(self(), :load_data)
    {:noreply, socket |> assign(:range, range) |> assign(:offset, 0) |> assign(:loading, true)}
  end

  def handle_event("filter", params, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:level, params["level"] || "all")
     |> assign(:service, params["service"] || "all")
     |> assign(:q, params["q"] || "")
     |> assign(:offset, 0)
     |> assign(:loading, true)}
  end

  def handle_event("clear_filters", _params, socket) do
    send(self(), :load_data)

    {:noreply,
     socket
     |> assign(:level, "all")
     |> assign(:service, "all")
     |> assign(:q, "")
     |> assign(:offset, 0)
     |> assign(:loading, true)}
  end

  def handle_event("next_page", _params, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:offset, socket.assigns.offset + 100) |> assign(:loading, true)}
  end

  def handle_event("prev_page", _params, socket) do
    new_offset = max(socket.assigns.offset - 100, 0)
    send(self(), :load_data)
    {:noreply, socket |> assign(:offset, new_offset) |> assign(:loading, true)}
  end

  def handle_event("toggle_group", %{"fingerprint" => fp}, socket) do
    if socket.assigns.expanded_fingerprint == fp do
      {:noreply, socket |> assign(:expanded_fingerprint, nil) |> assign(:expanded_logs, [])}
    else
      logs =
        Analytics.logs_for_fingerprint(socket.assigns.site.id, fp,
          hours: hours_for(socket.assigns.range)
        )

      {:noreply, socket |> assign(:expanded_fingerprint, fp) |> assign(:expanded_logs, logs)}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, range: range, level: level, service: service, q: q, tab: tab, offset: offset} =
      socket.assigns

    hours = hours_for(range)
    base_opts = [hours: hours, level: level, service: service, q: q]

    summary = Analytics.kpi_summary(site.id, base_opts)
    services = Analytics.top_services(site.id, hours: hours)
    chart_rows = Analytics.volume_by_level_hourly(site.id, base_opts)
    chart_data = build_chart_data(chart_rows)

    socket =
      socket
      |> assign(:summary, summary)
      |> assign(:services, services)
      |> assign(:chart_data, chart_data)
      |> assign(:chart_key, System.unique_integer([:positive]))

    case tab do
      "errors" ->
        groups = Analytics.error_groups(site.id, base_opts)
        assign(socket, :groups, groups)

      _ ->
        rows = Analytics.recent_logs(site.id, base_opts ++ [limit: 100, offset: offset])
        assign(socket, :rows, rows)
    end
  end

  defp hours_for("1h"), do: 1
  defp hours_for("24h"), do: 24
  defp hours_for("7d"), do: 24 * 7
  defp hours_for("30d"), do: 24 * 30
  defp hours_for(_), do: 24

  # Pivot CH rows (each row = {bucket, level, count}) into one
  # series per level for the stacked chart.
  defp build_chart_data(rows) do
    buckets =
      rows
      |> Enum.map(& &1.bucket)
      |> Enum.uniq()
      |> Enum.sort()

    by_bucket =
      Enum.group_by(rows, & &1.bucket, fn r -> {r.level, r.count} end)

    series = fn level ->
      Enum.map(buckets, fn b ->
        by_bucket
        |> Map.get(b, [])
        |> Enum.find_value(0, fn {l, c} -> if l == level, do: c, else: nil end)
      end)
    end

    %{
      labels: Enum.map(buckets, &format_bucket/1),
      info: series.("info"),
      warning: series.("warning"),
      error: series.("error"),
      critical: series.("critical")
    }
  end

  defp format_bucket(s) when is_binary(s) do
    # "2026-05-15 14:00:00" → "14:00 May 15"
    case String.split(s, " ") do
      [date, time] ->
        hhmm = String.slice(time, 0, 5)

        case String.split(date, "-") do
          [_y, m, d] -> "#{hhmm} #{month_abbr(m)} #{String.trim_leading(d, "0")}"
          _ -> "#{hhmm} #{date}"
        end

      _ ->
        s
    end
  end

  defp format_bucket(_), do: ""

  defp month_abbr("01"), do: "Jan"
  defp month_abbr("02"), do: "Feb"
  defp month_abbr("03"), do: "Mar"
  defp month_abbr("04"), do: "Apr"
  defp month_abbr("05"), do: "May"
  defp month_abbr("06"), do: "Jun"
  defp month_abbr("07"), do: "Jul"
  defp month_abbr("08"), do: "Aug"
  defp month_abbr("09"), do: "Sep"
  defp month_abbr("10"), do: "Oct"
  defp month_abbr("11"), do: "Nov"
  defp month_abbr("12"), do: "Dec"
  defp month_abbr(other), do: other

  defp level_pill_class("critical"), do: "bg-rose-200 text-rose-900"
  defp level_pill_class("error"), do: "bg-rose-100 text-rose-800"
  defp level_pill_class("warning"), do: "bg-amber-100 text-amber-800"
  defp level_pill_class("notice"), do: "bg-blue-100 text-blue-800"
  defp level_pill_class("info"), do: "bg-gray-100 text-gray-700"
  defp level_pill_class("debug"), do: "bg-gray-100 text-gray-500"
  defp level_pill_class(_), do: "bg-gray-100 text-gray-700"

  defp format_ts(s) when is_binary(s) do
    case String.split(s, ".") do
      [base, _ms_and_more] -> base
      _ -> s
    end
  end

  defp format_ts(_), do: ""

  defp format_relative(ts) when is_binary(ts) do
    with [date_str, time_str] <- String.split(ts, " "),
         {:ok, date} <- Date.from_iso8601(date_str),
         {:ok, time} <- Time.from_iso8601(time_with_seconds(time_str)),
         {:ok, dt} <- DateTime.new(date, time, "Etc/UTC") do
      diff = DateTime.diff(DateTime.utc_now(), dt, :second)

      cond do
        diff < 60 -> "#{diff}s ago"
        diff < 3600 -> "#{div(diff, 60)}m ago"
        diff < 86_400 -> "#{div(diff, 3600)}h ago"
        true -> "#{div(diff, 86_400)}d ago"
      end
    else
      _ -> ts
    end
  end

  defp format_relative(_), do: ""

  defp time_with_seconds(t) do
    case String.split(t, ".") do
      [base | _] -> base
      _ -> t
    end
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(_), do: "0"

  defp truncate(s, n) when is_binary(s) and byte_size(s) > n,
    do: String.slice(s, 0, n) <> "…"

  defp truncate(s, _) when is_binary(s), do: s
  defp truncate(_, _), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Logs"
      page_description="Server logs from your Render services, pulled every minute. Filter, search, and group errors by stack-trace fingerprint."
      active="logs"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Logs</h1>
            <p class="text-sm text-gray-500 mt-1">
              Cross-reference server-side events with traffic, conversions, and bot detection.
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={
                r <- [
                  {"1h", "1 hr"},
                  {"24h", "24 hrs"},
                  {"7d", "7 days"},
                  {"30d", "30 days"}
                ]
              }
              phx-click="change_range"
              phx-value-range={elem(r, 0)}
              class={[
                "px-3 py-1.5 text-sm font-medium rounded-md",
                if(@range == elem(r, 0),
                  do: "bg-white shadow text-gray-900",
                  else: "text-gray-600 hover:text-gray-900"
                )
              ]}
            >
              {elem(r, 1)}
            </button>
          </nav>
        </div>

        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Total logs</p>
            <p class="text-2xl font-bold text-gray-900">{format_number(@summary.total)}</p>
            <p class="text-[10px] text-gray-400 mt-0.5">in window</p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Errors</p>
            <p class="text-2xl font-bold text-rose-700">{format_number(@summary.errors)}</p>
            <p class="text-[10px] text-gray-400 mt-0.5">
              {format_number(@summary.error_groups)} distinct
            </p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Warnings</p>
            <p class="text-2xl font-bold text-amber-700">{format_number(@summary.warnings)}</p>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <p class="text-xs text-gray-500">Services</p>
            <p class="text-2xl font-bold text-gray-900">{format_number(@summary.services)}</p>
            <p class="text-[10px] text-gray-400 mt-0.5">reporting</p>
          </div>
        </div>

        <div
          :if={@chart_data.labels != []}
          class="bg-white rounded-lg shadow p-5 mb-6"
        >
          <h3 class="font-semibold text-gray-900 mb-3">Volume by level</h3>
          <div
            id={"logs-chart-#{@chart_key}"}
            phx-hook="LogsChart"
            phx-update="ignore"
            data-chart={Jason.encode!(@chart_data)}
          >
            <div style="height: 200px; position: relative;">
              <canvas></canvas>
            </div>
          </div>
        </div>

        <form
          phx-change="filter"
          class="bg-white rounded-lg shadow p-4 mb-4 flex flex-wrap gap-3 items-end"
        >
          <div class="flex-1 min-w-[200px]">
            <label class="block text-xs font-medium text-gray-500 mb-1">Search</label>
            <input
              type="text"
              name="q"
              value={@q}
              phx-debounce="350"
              placeholder="message contains…"
              class="block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
            />
          </div>
          <div>
            <label class="block text-xs font-medium text-gray-500 mb-1">Level</label>
            <select
              name="level"
              class="rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2 pr-8"
            >
              <option value="all" selected={@level == "all"}>All</option>
              <option
                :for={l <- ~w(critical error warning notice info debug)}
                value={l}
                selected={@level == l}
              >
                {String.capitalize(l)}
              </option>
            </select>
          </div>
          <div>
            <label class="block text-xs font-medium text-gray-500 mb-1">Service</label>
            <select
              name="service"
              class="rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2 pr-8"
            >
              <option value="all" selected={@service == "all"}>All</option>
              <option :for={s <- @services} value={s.source} selected={@service == s.source}>
                {s.source} ({format_number(s.count)})
              </option>
            </select>
          </div>
          <button
            :if={@q != "" or @level != "all" or @service != "all"}
            type="button"
            phx-click="clear_filters"
            class="px-3 py-2 text-xs text-gray-600 hover:text-gray-900 underline"
          >
            Clear
          </button>
        </form>

        <div class="bg-white rounded-lg shadow mb-4">
          <nav class="flex border-b border-gray-200 px-4">
            <button
              phx-click="change_tab"
              phx-value-tab="recent"
              class={[
                "px-4 py-3 text-sm font-medium border-b-2 -mb-px",
                if(@tab == "recent",
                  do: "border-indigo-600 text-indigo-600",
                  else: "border-transparent text-gray-500 hover:text-gray-700"
                )
              ]}
            >
              Recent
            </button>
            <button
              phx-click="change_tab"
              phx-value-tab="errors"
              class={[
                "px-4 py-3 text-sm font-medium border-b-2 -mb-px",
                if(@tab == "errors",
                  do: "border-indigo-600 text-indigo-600",
                  else: "border-transparent text-gray-500 hover:text-gray-700"
                )
              ]}
            >
              Error groups
              <span :if={@summary.error_groups > 0} class="ml-1 text-[11px] text-gray-400">
                ({format_number(@summary.error_groups)})
              </span>
            </button>
          </nav>

          <div :if={@loading} class="p-12 text-center text-sm text-gray-500">
            Loading…
          </div>

          <%!-- Recent tab --%>
          <div :if={!@loading and @tab == "recent"}>
            <div :if={@rows == []} class="p-12 text-center text-sm text-gray-500">
              No logs in this window. Settings → Server logs to configure ingest.
            </div>
            <ul :if={@rows != []} class="divide-y divide-gray-100">
              <li :for={row <- @rows} class="px-4 py-2.5 flex items-start gap-3 text-xs">
                <span class={[
                  "inline-flex shrink-0 px-2 py-0.5 rounded font-medium uppercase tracking-wide text-[10px]",
                  level_pill_class(row["level"])
                ]}>
                  {row["level"]}
                </span>
                <span class="shrink-0 text-gray-400 font-mono w-40">
                  {format_ts(row["timestamp"])}
                </span>
                <span
                  :if={row["source"] != ""}
                  class="shrink-0 text-gray-500 font-mono w-32 truncate"
                  title={row["source"]}
                >
                  {row["source"]}
                </span>
                <span class="flex-1 font-mono text-gray-800 break-all">
                  {truncate(row["message"], 400)}
                </span>
              </li>
            </ul>
            <div
              :if={@rows != []}
              class="px-4 py-3 flex items-center justify-between border-t border-gray-100 text-xs text-gray-500"
            >
              <span>Showing {@offset + 1}–{@offset + length(@rows)}</span>
              <div class="flex gap-2">
                <button
                  :if={@offset > 0}
                  phx-click="prev_page"
                  class="px-3 py-1 rounded border border-gray-300 hover:bg-gray-50"
                >
                  ← Newer
                </button>
                <button
                  :if={length(@rows) == 100}
                  phx-click="next_page"
                  class="px-3 py-1 rounded border border-gray-300 hover:bg-gray-50"
                >
                  Older →
                </button>
              </div>
            </div>
          </div>

          <%!-- Errors tab --%>
          <div :if={!@loading and @tab == "errors"}>
            <div :if={@groups == []} class="p-12 text-center text-sm text-gray-500">
              No error groups in this window.
            </div>
            <ul :if={@groups != []} class="divide-y divide-gray-100">
              <li :for={g <- @groups} class="text-xs">
                <button
                  type="button"
                  phx-click="toggle_group"
                  phx-value-fingerprint={g.fingerprint}
                  class="w-full px-4 py-3 flex items-start gap-3 text-left hover:bg-gray-50"
                >
                  <span class="shrink-0 text-rose-700 font-bold text-base w-12 text-right">
                    {format_number(g.count)}
                  </span>
                  <div class="flex-1 min-w-0">
                    <p class="font-mono text-gray-900 truncate">{truncate(g.sample_message, 200)}</p>
                    <p class="text-[10px] text-gray-400 mt-0.5">
                      <span :if={g.module != ""}>
                        <code class="font-mono">{g.module}</code><span :if={g.line > 0}>:{g.line}</span>
                        ·
                      </span>
                      <span :if={g.sample_source != ""}>{g.sample_source}  · </span>
                      last {format_relative(g.last_seen)} · first {format_relative(g.first_seen)}
                    </p>
                  </div>
                  <span class="shrink-0 text-gray-400 text-xs">
                    {if @expanded_fingerprint == g.fingerprint, do: "▾", else: "▸"}
                  </span>
                </button>
                <ul
                  :if={@expanded_fingerprint == g.fingerprint and @expanded_logs != []}
                  class="bg-gray-50 border-t border-gray-100 divide-y divide-gray-100"
                >
                  <li :for={l <- @expanded_logs} class="px-12 py-2 flex items-start gap-3">
                    <span class="shrink-0 text-gray-400 font-mono w-40">
                      {format_ts(l["timestamp"])}
                    </span>
                    <span class="flex-1 font-mono text-gray-700 break-all">
                      {truncate(l["message"], 600)}
                    </span>
                  </li>
                </ul>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
