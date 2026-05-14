defmodule SpectabasWeb.Dashboard.FormDetailLive do
  @moduledoc """
  Per-form deep-dive page. URL: `/dashboard/sites/:site_id/forms/:form_id`
  where `form_id` is URL-encoded (Phoenix handles encoding/decoding on
  both sides).

  Sections:
  - Header: form name + action + kind badge, back link, range selector,
    "Create cohort of abandoners" button (deep-links into the cohort
    builder with `form_abandoned` Segment field pre-filled).
  - KPI cards with period-over-period delta arrows.
  - Funnel viz (Views → Starts → Submits as a horizontal bar funnel).
  - Daily timeseries chart (Chart.js, via the existing TimeseriesChart
    hook).
  - Per-field drop-off table.
  - Top URLs hosting this form (single form can live on multiple pages).
  - Breakdown panels: device type, country, browser language, source.
  - Recent submits + abandons feed.
  - Time-to-submit distribution (p10/p50/p90 + suspicious-fast + slow
    counts).
  - Validation errors (field → count + sample message).
  - Per-field time spent (avg / p50 / p90 ms).
  - Submit trigger breakdown (cluster forms only).
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

  @breakdown_dimensions [
    {"device_type", "Device"},
    {"ip_country", "Country"},
    {"browser_language", "Language"},
    {"utm_source", "UTM source"}
  ]

  @impl true
  def mount(%{"site_id" => site_id, "form_id" => form_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Form: #{form_id} - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:form_id, form_id)
        |> assign(:date_range, "30d")
        |> assign(:kpis, %{})
        |> assign(:prev_kpis, %{})
        |> assign(:timeseries, [])
        |> assign(:timeseries_json, "{}")
        |> assign(:field_dropoff, [])
        |> assign(:top_urls, [])
        |> assign(:breakdowns, %{})
        |> assign(:recent_events, [])
        |> assign(:submit_triggers, [])
        |> assign(:time_to_submit, %{})
        |> assign(:validation_errors, [])
        |> assign(:field_times, [])
        |> assign(:breakdown_dimensions, @breakdown_dimensions)
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
    %{site: site, user: user, form_id: form_id, date_range: range} = socket.assigns
    period = range_to_period(range)
    date_range = Analytics.period_to_date_range(period, "UTC")
    prev_date_range = prev_equivalent_period(date_range)

    kpis =
      case Analytics.form_detail_kpis(site, user, form_id, date_range) do
        {:ok, [row]} -> row
        _ -> %{}
      end

    prev_kpis =
      case Analytics.form_detail_kpis(site, user, form_id, prev_date_range) do
        {:ok, [row]} -> row
        _ -> %{}
      end

    timeseries =
      case Analytics.form_timeseries(site, user, form_id, date_range) do
        {:ok, rows} -> rows
        _ -> []
      end

    field_dropoff =
      case Analytics.form_field_dropoff(site, user, form_id, date_range) do
        {:ok, rows} -> rows
        _ -> []
      end

    top_urls =
      case Analytics.form_top_urls(site, user, form_id, date_range) do
        {:ok, rows} -> rows
        _ -> []
      end

    breakdowns =
      @breakdown_dimensions
      |> Enum.map(fn {dim, _label} ->
        rows =
          case Analytics.form_breakdown(site, user, form_id, dim, date_range) do
            {:ok, rs} -> Enum.take(rs, 10)
            _ -> []
          end

        {dim, rows}
      end)
      |> Map.new()

    recent_events =
      case Analytics.form_recent_events(site, user, form_id, date_range) do
        {:ok, rows} -> rows
        _ -> []
      end

    submit_triggers =
      case Analytics.form_submit_triggers(site, user, form_id, date_range) do
        {:ok, rows} -> rows
        _ -> []
      end

    time_to_submit =
      case Analytics.form_time_to_submit_distribution(site, user, form_id, date_range) do
        {:ok, [row]} -> row
        _ -> %{}
      end

    validation_errors =
      case Analytics.form_validation_errors(site, user, form_id, date_range) do
        {:ok, rows} -> rows
        _ -> []
      end

    field_times =
      case Analytics.form_field_times(site, user, form_id, date_range) do
        {:ok, rows} -> rows
        _ -> []
      end

    socket
    |> assign(:kpis, kpis)
    |> assign(:prev_kpis, prev_kpis)
    |> assign(:timeseries, timeseries)
    |> assign(:timeseries_json, build_timeseries_json(timeseries))
    |> assign(:field_dropoff, field_dropoff)
    |> assign(:top_urls, top_urls)
    |> assign(:breakdowns, breakdowns)
    |> assign(:recent_events, recent_events)
    |> assign(:submit_triggers, submit_triggers)
    |> assign(:time_to_submit, time_to_submit)
    |> assign(:validation_errors, validation_errors)
    |> assign(:field_times, field_times)
  end

  defp prev_equivalent_period(%{from: from, to: to}) do
    diff = DateTime.diff(to, from, :second)
    %{from: DateTime.add(from, -diff, :second), to: from}
  end

  defp build_timeseries_json(rows) do
    Jason.encode!(%{
      labels: Enum.map(rows, &to_string(&1["day"])),
      visitors: Enum.map(rows, &to_num(&1["submits"])),
      label: "Submits",
      color: "#6366f1",
      bg_color: "rgba(99, 102, 241, 0.1)",
      value_suffix: "",
      metric: "submits"
    })
  rescue
    _ -> "{}"
  end

  defp delta(curr, prev) do
    c = to_num(curr)
    p = to_num(prev)

    cond do
      p == 0 and c == 0 -> {:flat, 0.0}
      p == 0 -> {:up, 100.0}
      true -> classify_delta((c - p) / p * 100)
    end
  end

  defp classify_delta(pct) when pct >= 1.0, do: {:up, Float.round(pct, 1)}
  defp classify_delta(pct) when pct <= -1.0, do: {:down, Float.round(pct, 1)}
  defp classify_delta(pct), do: {:flat, Float.round(pct, 1)}

  defp delta_class({:up, _}), do: "text-emerald-600"
  defp delta_class({:down, _}), do: "text-rose-600"
  defp delta_class(_), do: "text-gray-400"

  defp delta_arrow({:up, _}), do: "↑"
  defp delta_arrow({:down, _}), do: "↓"
  defp delta_arrow(_), do: "·"

  defp fmt_duration_ms(nil), do: "—"
  defp fmt_duration_ms(""), do: "—"

  defp fmt_duration_ms(ms) do
    n = to_num(ms)

    cond do
      n == 0 -> "—"
      n < 1000 -> "#{n} ms"
      n < 60_000 -> "#{Float.round(n / 1000, 1)} s"
      true -> "#{Float.round(n / 60_000, 1)} min"
    end
  end

  defp format_timestamp(ts) when is_binary(ts) do
    String.replace(ts, "T", " ") |> String.replace("Z", "")
  end

  defp format_timestamp(ts) when is_struct(ts, NaiveDateTime),
    do: NaiveDateTime.to_string(ts)

  defp format_timestamp(ts) when is_struct(ts, DateTime),
    do: DateTime.to_iso8601(ts) |> String.replace("T", " ")

  defp format_timestamp(other), do: to_string(other)

  defp short_visitor(vid) when is_binary(vid), do: String.slice(vid, 0, 8)
  defp short_visitor(_), do: "—"

  defp display_form_label(kpis, form_id) do
    name = kpis["form_name"]
    if name && name != "", do: name, else: form_id
  end

  defp kind_label("cluster"), do: "Cluster"
  defp kind_label("form"), do: "Form"
  defp kind_label(_), do: "—"

  defp kind_badge_class("cluster"),
    do: "inline-block px-2 py-0.5 rounded text-xs bg-indigo-100 text-indigo-800 font-medium"

  defp kind_badge_class("form"),
    do: "inline-block px-2 py-0.5 rounded text-xs bg-emerald-100 text-emerald-800 font-medium"

  defp kind_badge_class(_),
    do: "inline-block px-2 py-0.5 rounded text-xs bg-gray-100 text-gray-600 font-medium"

  defp breakdown_label("device_type"), do: "Device"
  defp breakdown_label("ip_country"), do: "Country"
  defp breakdown_label("browser_language"), do: "Language"
  defp breakdown_label("utm_source"), do: "UTM source"
  defp breakdown_label(d), do: d

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title={display_form_label(@kpis, @form_id)}
      page_description="Per-form deep-dive: funnel, breakdowns, validation errors, per-field times, recent activity."
      active="forms"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/forms"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            ← Forms
          </.link>
          <div class="flex items-start justify-between mt-2 gap-4">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <h1 class="text-2xl font-bold text-gray-900 truncate">
                  {display_form_label(@kpis, @form_id)}
                </h1>
                <span class={kind_badge_class(@kpis["form_kind"])}>
                  {kind_label(@kpis["form_kind"])}
                </span>
              </div>
              <p class="text-xs text-gray-500 mt-1 font-mono break-all">
                <span class="font-semibold">ID:</span> {@form_id}
              </p>
              <p
                :if={@kpis["form_action"] && @kpis["form_action"] != ""}
                class="text-xs text-gray-500 font-mono break-all"
              >
                <span class="font-semibold">Action:</span> {@kpis["form_action"]}
              </p>
            </div>
            <div class="flex flex-col gap-2 items-end">
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
              <.link
                navigate={
                  ~p"/dashboard/sites/#{@site.id}/cohorts?prefill_field=form_abandoned&prefill_value=#{@form_id}&prefill_name=#{"Abandoned: " <> display_form_label(@kpis, @form_id)}"
                }
                class="text-xs px-3 py-1.5 bg-indigo-600 hover:bg-indigo-700 text-white rounded-lg font-medium"
              >
                + Create cohort of abandoners
              </.link>
            </div>
          </div>
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
          <%!-- KPI cards with period-over-period delta --%>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
            <div
              :for={
                {label, key} <- [
                  {"Views", "views"},
                  {"Starts", "starts"},
                  {"Submits", "submits"},
                  {"Abandons", "abandons"}
                ]
              }
              class="bg-white rounded-lg shadow p-4"
            >
              <p class="text-xs text-gray-500">{label}</p>
              <p class="text-2xl font-bold text-gray-900">
                {format_number(to_num(@kpis[key] || 0))}
              </p>
              <% d = delta(@kpis[key], @prev_kpis[key]) %>
              <p class={["text-[10px] mt-0.5", delta_class(d)]}>
                {delta_arrow(d)} {elem(d, 1)}% vs prior {@date_range}
              </p>
            </div>
          </div>

          <%!-- Funnel visualization --%>
          <div class="bg-white rounded-lg shadow p-5 mb-6">
            <h2 class="text-sm font-semibold text-gray-700 mb-4">Conversion funnel</h2>
            <% views = max(to_num(@kpis["views"] || 0), 1) %>
            <% starts = to_num(@kpis["starts"] || 0) %>
            <% submits = to_num(@kpis["submits"] || 0) %>
            <% start_pct = round(starts / views * 100) %>
            <% submit_pct = round(submits / views * 100) %>
            <% start_to_submit_pct =
              if starts > 0, do: round(submits / starts * 100), else: 0 %>
            <div class="space-y-3">
              <div>
                <div class="flex items-center justify-between text-xs text-gray-600 mb-1">
                  <span class="font-medium">Views</span>
                  <span class="tabular-nums">
                    {format_number(to_num(@kpis["views"] || 0))} · 100%
                  </span>
                </div>
                <div class="h-8 bg-indigo-500 rounded-r-lg" style="width: 100%"></div>
              </div>
              <div>
                <div class="flex items-center justify-between text-xs text-gray-600 mb-1">
                  <span class="font-medium">Starts</span>
                  <span class="tabular-nums">{format_number(starts)} · {start_pct}% of views</span>
                </div>
                <div
                  class="h-8 bg-indigo-400 rounded-r-lg"
                  style={"width: #{start_pct}%; min-width: 2px"}
                >
                </div>
              </div>
              <div>
                <div class="flex items-center justify-between text-xs text-gray-600 mb-1">
                  <span class="font-medium">Submits</span>
                  <span class="tabular-nums">
                    {format_number(submits)} · {submit_pct}% of views · {start_to_submit_pct}% of starters
                  </span>
                </div>
                <div
                  class="h-8 bg-emerald-500 rounded-r-lg"
                  style={"width: #{submit_pct}%; min-width: 2px"}
                >
                </div>
              </div>
            </div>
          </div>

          <%!-- Timeseries chart --%>
          <div :if={@timeseries != []} class="bg-white rounded-lg shadow p-5 mb-6">
            <h2 class="text-sm font-semibold text-gray-700 mb-3">Submits over time</h2>
            <div
              id={"form-timeseries-#{@form_id}-#{@date_range}"}
              phx-hook="TimeseriesChart"
              phx-update="ignore"
              data-chart={@timeseries_json}
              class="h-48 sm:h-[240px] relative"
            >
              <canvas></canvas>
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
            <%!-- Per-field drop-off --%>
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-100">
                <h2 class="text-sm font-semibold text-gray-700">Per-field drop-off</h2>
                <p class="text-[10px] text-gray-400 mt-0.5">
                  Field where each visitor abandoned. The top row is your funnel breakpoint.
                </p>
              </div>
              <table class="min-w-full text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Field
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Starts here
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Abandons
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :if={@field_dropoff == []}>
                    <td colspan="3" class="px-5 py-3 text-center text-gray-400 text-xs">
                      No field-level data yet.
                    </td>
                  </tr>
                  <tr :for={r <- @field_dropoff}>
                    <td class="px-5 py-2 font-mono text-xs">{r["field_name"]}</td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["starts_here"]))}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs text-amber-700">
                      {format_number(to_num(r["abandons"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Per-field time spent --%>
            <div class="bg-white rounded-lg shadow overflow-hidden">
              <div class="px-5 py-3 border-b border-gray-100">
                <h2 class="text-sm font-semibold text-gray-700">Time per field</h2>
                <p class="text-[10px] text-gray-400 mt-0.5">
                  Average ms visitors spend with each field focused. Long times = friction (long-prompt field, validation re-tries).
                </p>
              </div>
              <table class="min-w-full text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Field
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Avg
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      p90
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      n
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :if={@field_times == []}>
                    <td colspan="4" class="px-5 py-3 text-center text-gray-400 text-xs">
                      No field-time data yet. Tracker started reporting per-field times in v6.10.38.
                    </td>
                  </tr>
                  <tr :for={r <- @field_times}>
                    <td class="px-5 py-2 font-mono text-xs">{r["field_name"]}</td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {fmt_duration_ms(r["avg_ms"])}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {fmt_duration_ms(r["p90_ms"])}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["samples"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Top URLs --%>
          <div class="bg-white rounded-lg shadow overflow-hidden mb-6">
            <div class="px-5 py-3 border-b border-gray-100">
              <h2 class="text-sm font-semibold text-gray-700">Pages hosting this form</h2>
              <p class="text-[10px] text-gray-400 mt-0.5">
                Same form_id can appear on multiple URLs; this shows which page each interaction came from.
              </p>
            </div>
            <table class="min-w-full text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">URL</th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Views
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Submits
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Submit %
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@top_urls == []}>
                  <td colspan="4" class="px-5 py-3 text-center text-gray-400 text-xs">
                    No URL data yet.
                  </td>
                </tr>
                <tr :for={r <- @top_urls}>
                  <td class="px-5 py-2 font-mono text-xs truncate max-w-md">{r["url_path"]}</td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["views"]))}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["submits"]))}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {to_num(r["submit_rate"])}%
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Breakdown grid --%>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
            <div
              :for={{dim, _label} <- @breakdown_dimensions}
              class="bg-white rounded-lg shadow overflow-hidden"
            >
              <div class="px-5 py-3 border-b border-gray-100">
                <h2 class="text-sm font-semibold text-gray-700">By {breakdown_label(dim)}</h2>
              </div>
              <table class="min-w-full text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      {breakdown_label(dim)}
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Views
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Submits
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Submit %
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :if={Map.get(@breakdowns, dim, []) == []}>
                    <td colspan="4" class="px-5 py-3 text-center text-gray-400 text-xs">
                      No data.
                    </td>
                  </tr>
                  <tr :for={r <- Map.get(@breakdowns, dim, [])}>
                    <td class="px-5 py-2 font-mono text-xs truncate max-w-[10rem]">
                      {r["dimension_value"]}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["views"]))}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {format_number(to_num(r["submits"]))}
                    </td>
                    <td class="px-5 py-2 text-right tabular-nums text-xs">
                      {to_num(r["submit_rate"])}%
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Time-to-submit distribution + cluster trigger breakdown --%>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-6">
            <div class="bg-white rounded-lg shadow p-5">
              <h2 class="text-sm font-semibold text-gray-700 mb-3">Time-to-submit</h2>
              <p :if={to_num(@time_to_submit["samples"] || 0) == 0} class="text-xs text-gray-400">
                No timing data yet. The tracker started reporting `_t_to_submit` in v6.10.38; values will appear as new submits come in.
              </p>
              <dl
                :if={to_num(@time_to_submit["samples"] || 0) > 0}
                class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm"
              >
                <dt class="text-xs text-gray-500">p10 (fastest 10%)</dt>
                <dd class="text-xs text-right tabular-nums">
                  {fmt_duration_ms(@time_to_submit["p10_ms"])}
                </dd>
                <dt class="text-xs text-gray-500">p50 (median)</dt>
                <dd class="text-xs text-right tabular-nums font-medium">
                  {fmt_duration_ms(@time_to_submit["p50_ms"])}
                </dd>
                <dt class="text-xs text-gray-500">p90</dt>
                <dd class="text-xs text-right tabular-nums">
                  {fmt_duration_ms(@time_to_submit["p90_ms"])}
                </dd>
                <dt class="text-xs text-gray-500">Avg</dt>
                <dd class="text-xs text-right tabular-nums">
                  {fmt_duration_ms(@time_to_submit["avg_ms"])}
                </dd>
                <dt class="text-xs text-rose-600">Suspicious &lt; 2s</dt>
                <dd class="text-xs text-right tabular-nums text-rose-600">
                  {format_number(to_num(@time_to_submit["suspicious_fast"]))} of {format_number(
                    to_num(@time_to_submit["samples"])
                  )}
                </dd>
                <dt class="text-xs text-amber-700">Slow &gt; 60s</dt>
                <dd class="text-xs text-right tabular-nums text-amber-700">
                  {format_number(to_num(@time_to_submit["slow_friction"]))} of {format_number(
                    to_num(@time_to_submit["samples"])
                  )}
                </dd>
              </dl>
            </div>

            <div class="bg-white rounded-lg shadow p-5">
              <h2 class="text-sm font-semibold text-gray-700 mb-1">Submit trigger</h2>
              <p class="text-[10px] text-gray-400 mb-3">
                For cluster forms, splits submits by how they were detected. "Native" = browser submit event (always for &lt;form&gt;-kind, can also occur on clusters that wrap a real form). "Button text" = inferred from a click on a submit-verb button (the heuristic).
              </p>
              <table class="min-w-full text-sm">
                <tbody class="divide-y divide-gray-100">
                  <tr :if={@submit_triggers == []}>
                    <td colspan="2" class="px-2 py-2 text-center text-gray-400 text-xs">
                      No submits yet.
                    </td>
                  </tr>
                  <tr :for={r <- @submit_triggers}>
                    <td class="px-2 py-2 text-xs">
                      <span class={
                        if(r["trigger"] == "native",
                          do:
                            "inline-block px-1.5 py-0.5 rounded bg-emerald-50 text-emerald-700 font-medium",
                          else:
                            "inline-block px-1.5 py-0.5 rounded bg-indigo-50 text-indigo-700 font-medium"
                        )
                      }>
                        {r["trigger"]}
                      </span>
                    </td>
                    <td class="px-2 py-2 text-right tabular-nums text-xs font-medium">
                      {format_number(to_num(r["submits"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%!-- Validation errors --%>
          <div class="bg-white rounded-lg shadow overflow-hidden mb-6">
            <div class="px-5 py-3 border-b border-gray-100">
              <h2 class="text-sm font-semibold text-gray-700">Validation errors</h2>
              <p class="text-[10px] text-gray-400 mt-0.5">
                Fired when the browser's HTML5 form validation rejects an input. High counts often mean an unclear constraint (regex, min-length) — typically fixable with a better label or inline help text.
              </p>
            </div>
            <table class="min-w-full text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Field
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Type
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Sample message
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Errors
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Visitors
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@validation_errors == []}>
                  <td colspan="5" class="px-5 py-3 text-center text-gray-400 text-xs">
                    No validation errors recorded.
                  </td>
                </tr>
                <tr :for={r <- @validation_errors}>
                  <td class="px-5 py-2 font-mono text-xs">{r["field_name"]}</td>
                  <td class="px-5 py-2 text-xs text-gray-500">{r["field_type"]}</td>
                  <td class="px-5 py-2 text-xs text-gray-600 truncate max-w-md">
                    {r["sample_message"]}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs text-rose-700">
                    {format_number(to_num(r["errors"]))}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs">
                    {format_number(to_num(r["affected_visitors"]))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Recent events feed --%>
          <div class="bg-white rounded-lg shadow overflow-hidden">
            <div class="px-5 py-3 border-b border-gray-100">
              <h2 class="text-sm font-semibold text-gray-700">Recent activity</h2>
              <p class="text-[10px] text-gray-400 mt-0.5">
                Last 50 submit or abandon events. Visitor IDs link to the full visitor profile for context.
              </p>
            </div>
            <table class="min-w-full text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    When
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Event
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Visitor
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    URL
                  </th>
                  <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                    Last field
                  </th>
                  <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                    Time
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@recent_events == []}>
                  <td colspan="6" class="px-5 py-3 text-center text-gray-400 text-xs">
                    No recent submit / abandon events in this range.
                  </td>
                </tr>
                <tr :for={e <- @recent_events}>
                  <td class="px-5 py-2 text-xs text-gray-500 tabular-nums">
                    {format_timestamp(e["timestamp"])}
                  </td>
                  <td class="px-5 py-2 text-xs">
                    <span class={
                      if(e["event_name"] == "_form_submit",
                        do:
                          "inline-block px-1.5 py-0.5 rounded bg-emerald-50 text-emerald-700 font-medium",
                        else:
                          "inline-block px-1.5 py-0.5 rounded bg-amber-50 text-amber-700 font-medium"
                      )
                    }>
                      {String.replace(e["event_name"] || "", "_form_", "")}
                    </span>
                  </td>
                  <td class="px-5 py-2 text-xs">
                    <.link
                      navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{e["visitor_id"]}"}
                      class="font-mono text-indigo-600 hover:text-indigo-800"
                    >
                      {short_visitor(e["visitor_id"])}
                    </.link>
                  </td>
                  <td class="px-5 py-2 text-xs text-gray-600 truncate max-w-xs font-mono">
                    {e["url_path"]}
                  </td>
                  <td class="px-5 py-2 text-xs font-mono text-gray-500">
                    {e["last_field"]}
                  </td>
                  <td class="px-5 py-2 text-right tabular-nums text-xs text-gray-500">
                    {fmt_duration_ms(
                      if(e["event_name"] == "_form_submit",
                        do: e["t_to_submit_ms"],
                        else: e["t_to_abandon_ms"]
                      )
                    )}
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
