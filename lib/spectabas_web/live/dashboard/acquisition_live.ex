defmodule SpectabasWeb.Dashboard.AcquisitionLive do
  @moduledoc "Consolidated acquisition page — channels, sources, and attribution in one view."

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  alias Spectabas.Analytics.ChannelClassifier
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @utm_tabs [
    {"referrers", "Referrers"},
    {"utm_source", "UTM Source"},
    {"utm_medium", "UTM Medium"},
    {"utm_campaign", "UTM Campaign"},
    {"utm_term", "UTM Term"},
    {"utm_content", "UTM Content"}
  ]

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Acquisition - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:view, "channels")
        |> assign(:tab, "referrers")
        |> assign(:selected_channel, nil)
        |> assign(:utm_tabs, @utm_tabs)
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :sources}} = socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:view, "sources") |> assign(:loading, true)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("switch_view", %{"view" => view}, socket) do
    send(self(), :load_data)

    {:noreply,
     socket |> assign(:view, view) |> assign(:selected_channel, nil) |> assign(:loading, true)}
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:tab, tab) |> assign(:loading, true)}
  end

  def handle_event("select_channel", %{"channel" => channel}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:selected_channel, channel) |> assign(:loading, true)}
  end

  def handle_event("back_to_channels", _params, socket) do
    {:noreply, socket |> assign(:selected_channel, nil)}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, view: view} = socket.assigns
    period = range_to_period(range)

    case view do
      "channels" ->
        channels = safe_query(fn -> Analytics.channel_breakdown(site, user, period) end)

        detail =
          if socket.assigns.selected_channel do
            safe_query(fn ->
              Analytics.channel_detail(site, user, period, socket.assigns.selected_channel)
            end)
          else
            []
          end

        # Enrich channel detail with engagement metrics from daily_session_facts
        detail = enrich_with_engagement(detail, site, user, period, "referrer_domain")

        socket
        |> assign(:channels, channels)
        |> assign(:channel_detail, detail)

      "sources" ->
        tab = socket.assigns.tab
        sources = load_sources(site, user, period, tab)

        # Map tab → session_facts column for engagement lookup
        eng_dim =
          case tab do
            "referrers" -> "referrer_domain"
            "utm_source" -> "utm_source"
            "utm_medium" -> "utm_medium"
            "utm_campaign" -> "utm_campaign"
            "utm_term" -> nil
            "utm_content" -> nil
            _ -> nil
          end

        sources =
          if eng_dim,
            do: enrich_with_engagement(sources, site, user, period, eng_dim),
            else: sources

        assign(socket, :sources, sources)
    end
  end

  # Merge engagement metrics from daily_session_facts into existing rows.
  # Each row gets "bounce_rate", "avg_duration", "pages_per_session" keys.
  defp enrich_with_engagement([], _site, _user, _period, _dim), do: []

  defp enrich_with_engagement(rows, site, user, period, dim) do
    engagement =
      case Analytics.source_engagement(site, user, period, dim) do
        {:ok, map} -> map
        _ -> %{}
      end

    # The key in engagement map matches the dimension value in the row.
    # For referrers: row["referrer_domain"] or row["source"]
    Enum.map(rows, fn row ->
      key = row["referrer_domain"] || row["source"] || row["value"] || ""

      case Map.get(engagement, key) do
        %{bounce_rate: br, avg_duration: dur, pages_per_session: pps} ->
          row
          |> Map.put("bounce_rate", to_string(br))
          |> Map.put("avg_duration", to_string(dur))
          |> Map.put("pages_per_session", to_string(pps))

        _ ->
          row
          |> Map.put("bounce_rate", nil)
          |> Map.put("avg_duration", nil)
          |> Map.put("pages_per_session", nil)
      end
    end)
  end

  defp load_sources(site, user, period, tab) do
    result =
      case tab do
        "referrers" -> Analytics.top_sources(site, user, period)
        "utm_source" -> Analytics.top_utm_sources(site, user, period)
        "utm_medium" -> Analytics.top_utm_mediums(site, user, period)
        "utm_campaign" -> Analytics.top_utm_campaigns(site, user, period)
        "utm_term" -> Analytics.top_utm_terms(site, user, period)
        "utm_content" -> Analytics.top_utm_content(site, user, period)
        _ -> {:ok, []}
      end

    case result do
      {:ok, data} -> data
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Acquisition"
      page_description="Where your visitors come from — channels, sources, UTM parameters, and attribution."
      active="acquisition"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Acquisition</h1>
          <div class="flex gap-2">
            <%!-- View Toggle --%>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={{id, label} <- [{"channels", "Channels"}, {"sources", "Sources"}]}
                phx-click="switch_view"
                phx-value-view={id}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
                  if(@view == id,
                    do: "bg-white shadow text-gray-900",
                    else: "text-gray-600 hover:text-gray-900"
                  )
                ]}
              >
                {label}
              </button>
            </nav>
            <%!-- Date Range --%>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={r <- [{"24h", "24h"}, {"7d", "7d"}, {"30d", "30d"}]}
                phx-click="change_range"
                phx-value-range={elem(r, 0)}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
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
          <%!-- Channels View --%>
          <div :if={@view == "channels"}>
            <%!-- Channel Detail (drill-down) --%>
            <div :if={@selected_channel}>
              <button
                phx-click="back_to_channels"
                class="text-sm text-indigo-600 hover:text-indigo-800 mb-4 inline-flex items-center gap-1"
              >
                &larr; All Channels
              </button>
              <h2 class="text-lg font-semibold text-gray-900 mb-4">
                <span class={[
                  "inline-block px-2.5 py-0.5 rounded-full text-xs font-medium mr-2",
                  ChannelClassifier.channel_color(@selected_channel)
                ]}>
                  {@selected_channel}
                </span>
                Sources
              </h2>
              <div class="bg-white rounded-lg shadow overflow-x-auto">
                <table class="min-w-full divide-y divide-gray-200">
                  <thead class="bg-gray-50">
                    <tr>
                      <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                        Source
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                        Pageviews
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                        Visitors
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                        Sessions
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                        Bounce
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                        Duration
                      </th>
                      <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase hidden lg:table-cell">
                        Pages/Sess
                      </th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-gray-100">
                    <tr :if={@channel_detail == []}>
                      <td colspan="7" class="px-6 py-8 text-center text-gray-500">
                        No sources for this channel.
                      </td>
                    </tr>
                    <tr :for={src <- @channel_detail} class="hover:bg-gray-50">
                      <td class="px-6 py-4 text-sm text-indigo-600 font-medium">{src["source"]}</td>
                      <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                        {format_number(to_num(src["pageviews"]))}
                      </td>
                      <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                        {format_number(to_num(src["visitors"]))}
                      </td>
                      <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                        {format_number(to_num(src["sessions"]))}
                      </td>
                      <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums hidden md:table-cell">
                        {if src["bounce_rate"], do: "#{src["bounce_rate"]}%", else: "—"}
                      </td>
                      <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums hidden md:table-cell">
                        {if src["avg_duration"],
                          do: format_duration(to_num(src["avg_duration"])),
                          else: "—"}
                      </td>
                      <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums hidden lg:table-cell">
                        {src["pages_per_session"] || "—"}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>

            <%!-- Channel Overview --%>
            <div :if={!@selected_channel} class="bg-white rounded-lg shadow overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      Channel
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Sessions
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Pageviews
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Bounce Rate
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Avg Duration
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Pages/Session
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :if={@channels == []}>
                    <td colspan="7" class="px-6 py-8 text-center text-gray-500">
                      No data for this period.
                    </td>
                  </tr>
                  <tr
                    :for={ch <- @channels}
                    class="hover:bg-gray-50 cursor-pointer"
                    phx-click="select_channel"
                    phx-value-channel={ch["channel"]}
                  >
                    <td class="px-6 py-4 text-sm">
                      <span class={[
                        "inline-block px-2.5 py-0.5 rounded-full text-xs font-medium",
                        ChannelClassifier.channel_color(ch["channel"])
                      ]}>
                        {ch["channel"]}
                      </span>
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(ch["visitors"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(ch["sessions"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(ch["pageviews"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                      {ch["bounce_rate"]}%
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                      {format_duration(to_num(ch["avg_duration"]))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                      {ch["pages_per_session"]}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p :if={!@selected_channel && @channels != []} class="text-xs text-gray-500 mt-2">
              Click a channel to see individual sources within it.
            </p>
          </div>

          <%!-- Sources View --%>
          <div :if={@view == "sources"}>
            <div class="mb-6 flex flex-wrap gap-2">
              <button
                :for={{id, label} <- @utm_tabs}
                phx-click="change_tab"
                phx-value-tab={id}
                class={[
                  "px-4 py-2 text-sm font-medium rounded-md",
                  if(@tab == id,
                    do: "bg-indigo-600 text-white",
                    else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
                  )
                ]}
              >
                {label}
              </button>
            </div>

            <div class="bg-white rounded-lg shadow overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      Source
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Pageviews
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Sessions
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                      Bounce
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase hidden md:table-cell">
                      Duration
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase hidden lg:table-cell">
                      Pages/Sess
                    </th>
                  </tr>
                </thead>
                <tbody class="bg-white divide-y divide-gray-200">
                  <tr :if={@sources == []}>
                    <td colspan="6" class="px-6 py-8 text-center text-gray-500">
                      No data for this period.
                    </td>
                  </tr>
                  <tr :for={source <- @sources} class="hover:bg-gray-50">
                    <td class="px-6 py-4 text-sm">
                      <.link
                        navigate={source_link(@site.id, source, @tab)}
                        class="text-indigo-600 hover:text-indigo-800"
                      >
                        {source_name(source, @tab)}
                      </.link>
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(Map.get(source, "pageviews", 0)))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(Map.get(source, "sessions", 0)))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums hidden md:table-cell">
                      {if source["bounce_rate"], do: "#{source["bounce_rate"]}%", else: "—"}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums hidden md:table-cell">
                      {if source["avg_duration"],
                        do: format_duration(to_num(source["avg_duration"])),
                        else: "—"}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums hidden lg:table-cell">
                      {source["pages_per_session"] || "—"}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp source_name(source, "referrers"), do: Map.get(source, "referrer_domain", "Direct / None")
  defp source_name(source, _tab), do: Map.get(source, "value", "")

  defp source_link(site_id, source, "referrers") do
    domain = Map.get(source, "referrer_domain", "")

    ~p"/dashboard/sites/#{site_id}/visitor-log?filter_field=referrer_domain&filter_value=#{domain}"
  end

  defp source_link(site_id, source, tab) do
    val = Map.get(source, "value", "")
    ~p"/dashboard/sites/#{site_id}/visitor-log?filter_field=#{tab}&filter_value=#{val}"
  end
end
