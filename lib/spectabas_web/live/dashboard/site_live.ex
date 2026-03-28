defmodule SpectabasWeb.Dashboard.SiteLive do
  use SpectabasWeb, :live_view

  import SpectabasWeb.Dashboard.SegmentComponent

  alias Spectabas.{Accounts, Sites, Analytics}

  @refresh_interval_ms 60_000

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Spectabas.PubSub, "site:#{site.id}")
        schedule_refresh()
      end

      today = Date.utc_today()

      {:ok,
       socket
       |> assign(:page_title, site.name)
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:preset, "7d")
       |> assign(:date_from, Date.add(today, -7))
       |> assign(:date_to, today)
       |> assign(:compare, true)
       |> assign(:show_date_picker, false)
       |> assign(:segment, [])
       |> assign(:live_visitors, 0)
       |> load_stats()}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_stats(socket)}
  end

  def handle_info({:new_event, _event}, socket) do
    live_visitors =
      case Analytics.realtime_visitors(socket.assigns.site) do
        {:ok, count} -> count
        _ -> socket.assigns.live_visitors
      end

    {:noreply, assign(socket, :live_visitors, live_visitors)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("preset", %{"range" => range}, socket) do
    today = Date.utc_today()

    {from, to} =
      case range do
        "24h" -> {Date.add(today, -1), today}
        "7d" -> {Date.add(today, -7), today}
        "30d" -> {Date.add(today, -30), today}
        "90d" -> {Date.add(today, -90), today}
        "ytd" -> {Date.new!(today.year, 1, 1), today}
        "12m" -> {Date.add(today, -365), today}
        _ -> {Date.add(today, -7), today}
      end

    {:noreply,
     socket
     |> assign(:preset, range)
     |> assign(:date_from, from)
     |> assign(:date_to, to)
     |> assign(:show_date_picker, false)
     |> load_stats()}
  end

  def handle_event("toggle_date_picker", _params, socket) do
    {:noreply, assign(socket, :show_date_picker, !socket.assigns.show_date_picker)}
  end

  def handle_event("custom_range", %{"from" => from_str, "to" => to_str}, socket) do
    with {:ok, from} <- Date.from_iso8601(from_str),
         {:ok, to} <- Date.from_iso8601(to_str) do
      {:noreply,
       socket
       |> assign(:preset, "custom")
       |> assign(:date_from, from)
       |> assign(:date_to, to)
       |> assign(:show_date_picker, false)
       |> load_stats()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "update_segment",
        %{"action" => "add", "field" => f, "op" => op, "value" => v},
        socket
      )
      when v != "" do
    filter = %{"field" => f, "op" => op, "value" => v}
    {:noreply, socket |> assign(:segment, socket.assigns.segment ++ [filter]) |> load_stats()}
  end

  def handle_event("update_segment", %{"action" => "remove", "index" => idx}, socket) do
    idx = String.to_integer(idx)
    segment = List.delete_at(socket.assigns.segment, idx)
    {:noreply, socket |> assign(:segment, segment) |> load_stats()}
  end

  def handle_event("update_segment", %{"action" => "clear"}, socket) do
    {:noreply, socket |> assign(:segment, []) |> load_stats()}
  end

  def handle_event("update_segment", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_compare", _params, socket) do
    {:noreply,
     socket
     |> assign(:compare, !socket.assigns.compare)
     |> load_stats()}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp load_stats(socket) do
    require Logger

    %{
      site: site,
      user: user,
      date_from: from,
      date_to: to,
      compare: compare,
      preset: preset,
      segment: segment
    } = socket.assigns

    seg_opts = [segment: segment]

    date_range = %{
      from: DateTime.new!(from, ~T[00:00:00]),
      to: DateTime.new!(to, ~T[23:59:59])
    }

    period = preset_to_period(preset, from, to)

    stats =
      case Analytics.overview_stats(site, user, date_range, seg_opts) do
        {:ok, s} ->
          %{
            pageviews: to_num(s["pageviews"]),
            unique_visitors: to_num(s["unique_visitors"]),
            sessions: to_num(s["total_sessions"]),
            bounce_rate: to_float(s["bounce_rate"]),
            avg_duration: to_num(s["avg_duration"])
          }

        _ ->
          %{pageviews: 0, unique_visitors: 0, sessions: 0, bounce_rate: 0.0, avg_duration: 0}
      end

    # Comparison period
    prev_stats =
      if compare do
        days = Date.diff(to, from)

        prev_range = %{
          from: DateTime.new!(Date.add(from, -(days + 1)), ~T[00:00:00]),
          to: DateTime.new!(Date.add(from, -1), ~T[23:59:59])
        }

        case Analytics.overview_stats(site, user, prev_range) do
          {:ok, s} ->
            %{
              pageviews: to_num(s["pageviews"]),
              unique_visitors: to_num(s["unique_visitors"]),
              sessions: to_num(s["total_sessions"]),
              bounce_rate: to_float(s["bounce_rate"]),
              avg_duration: to_num(s["avg_duration"])
            }

          _ ->
            nil
        end
      else
        nil
      end

    timeseries =
      case Analytics.timeseries(site, user, date_range, period) do
        {:ok, rows} -> rows
        _ -> []
      end

    top_pages = safe_query(fn -> Analytics.top_pages(site, user, date_range, seg_opts) end, 5)
    top_sources = safe_query(fn -> Analytics.top_sources(site, user, date_range) end, 5)
    top_regions = safe_query(fn -> Analytics.top_regions(site, user, date_range) end, 5)
    top_browsers = safe_query(fn -> Analytics.top_browsers(site, user, date_range) end, 5)
    top_os = safe_query(fn -> Analytics.top_os(site, user, date_range) end, 5)
    entry_pages = safe_query(fn -> Analytics.entry_pages(site, user, date_range) end, 5)
    locations = safe_query(fn -> Analytics.visitor_locations(site, user, date_range) end, 50)
    timezones = safe_query(fn -> Analytics.timezone_distribution(site, user, date_range) end, 5)

    live_visitors =
      case Analytics.realtime_visitors(site) do
        {:ok, count} -> count
        _ -> 0
      end

    socket
    |> assign(:stats, stats)
    |> assign(:prev_stats, prev_stats)
    |> assign(:timeseries, timeseries)
    |> assign(:live_visitors, live_visitors)
    |> assign(:top_pages, top_pages)
    |> assign(:top_sources, top_sources)
    |> assign(:top_regions, top_regions)
    |> assign(:top_browsers, top_browsers)
    |> assign(:top_os, top_os)
    |> assign(:entry_pages, entry_pages)
    |> assign(:locations, locations)
    |> assign(:timezones, timezones)
    |> push_chart_data(timeseries, locations, timezones)
  end

  defp push_chart_data(socket, timeseries, locations, timezones) do
    if Phoenix.LiveView.connected?(socket) do
      socket
      |> push_event("timeseries-data", %{
        labels: Enum.map(timeseries, & &1["label"]),
        pageviews: Enum.map(timeseries, &to_num(&1["pageviews"])),
        visitors: Enum.map(timeseries, &to_num(&1["visitors"]))
      })
      |> push_event("map-data", %{
        points:
          Enum.map(locations, fn loc ->
            %{
              lat: to_float(loc["ip_lat"]),
              lon: to_float(loc["ip_lon"]),
              visitors: to_num(loc["visitors"]),
              label: location_label(loc)
            }
          end)
      })
      |> push_event("bar-data", %{
        labels: Enum.map(timezones, &short_tz(&1["timezone"])),
        values: Enum.map(timezones, &to_num(&1["visitors"]))
      })
    else
      socket
    end
  end

  defp preset_to_period("24h", _, _), do: :day
  defp preset_to_period("7d", _, _), do: :week
  defp preset_to_period("30d", _, _), do: :month

  defp preset_to_period(_, from, to) do
    days = Date.diff(to, from)

    cond do
      days <= 2 -> :day
      days <= 31 -> :week
      true -> :month
    end
  end

  defp safe_query(fun, limit) do
    case fun.() do
      {:ok, rows} when is_list(rows) -> Enum.take(rows, limit)
      _ -> []
    end
  end

  defp range_label(from, to) do
    "#{Calendar.strftime(from, "%b %d")} - #{Calendar.strftime(to, "%b %d, %Y")}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <%!-- Header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <div class="flex items-center gap-3">
            <h1 class="text-2xl font-bold text-gray-900">{@site.name}</h1>
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/settings"}
              class="text-sm text-indigo-600 hover:text-indigo-800 border border-indigo-200 rounded-md px-2.5 py-1"
            >
              Settings
            </.link>
          </div>
          <p class="text-sm text-gray-500">{@site.domain}</p>
        </div>
        <div class="flex items-center gap-3">
          <div class="flex items-center gap-2 bg-green-50 text-green-700 px-3 py-1.5 rounded-full text-sm font-medium">
            <span class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></span>
            {@live_visitors} online now
          </div>
        </div>
      </div>

      <%!-- Date Controls --%>
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-2">
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={
                {id, label} <- [
                  {"24h", "24h"},
                  {"7d", "7d"},
                  {"30d", "30d"},
                  {"90d", "90d"},
                  {"12m", "12m"}
                ]
              }
              phx-click="preset"
              phx-value-range={id}
              class={[
                "px-2.5 py-1 text-sm font-medium rounded-md",
                if(@preset == id,
                  do: "bg-white shadow text-gray-900",
                  else: "text-gray-600 hover:text-gray-900"
                )
              ]}
            >
              {label}
            </button>
          </nav>
          <div class="relative">
            <button
              phx-click="toggle_date_picker"
              class={[
                "px-3 py-1.5 text-sm font-medium rounded-lg border",
                if(@preset == "custom",
                  do: "bg-indigo-50 border-indigo-200 text-indigo-700",
                  else: "bg-white border-gray-200 text-gray-700 hover:bg-gray-50"
                )
              ]}
            >
              {range_label(@date_from, @date_to)}
            </button>
            <div
              :if={@show_date_picker}
              class="absolute top-full mt-2 right-0 bg-white rounded-lg shadow-lg border border-gray-200 p-4 z-50"
            >
              <form phx-submit="custom_range" class="flex items-end gap-3">
                <div>
                  <label class="block text-xs font-medium text-gray-500 mb-1">From</label>
                  <input
                    type="date"
                    name="from"
                    value={Date.to_iso8601(@date_from)}
                    class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-gray-500 mb-1">To</label>
                  <input
                    type="date"
                    name="to"
                    value={Date.to_iso8601(@date_to)}
                    class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
                  />
                </div>
                <button
                  type="submit"
                  class="px-3 py-2 text-sm font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700"
                >
                  Apply
                </button>
              </form>
            </div>
          </div>
        </div>
        <button
          phx-click="toggle_compare"
          class={[
            "px-3 py-1.5 text-sm font-medium rounded-lg border",
            if(@compare,
              do: "bg-indigo-50 border-indigo-200 text-indigo-700",
              else: "bg-white border-gray-200 text-gray-600 hover:bg-gray-50"
            )
          ]}
        >
          Compare
        </button>
      </div>

      <%!-- Segment Filter --%>
      <.segment_filter segment={@segment} />

      <%!-- Stat Cards with Comparison --%>
      <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
        <.stat_card
          label="Pageviews"
          value={format_number(@stats.pageviews)}
          prev={@prev_stats && @prev_stats.pageviews}
          current={@stats.pageviews}
        />
        <.stat_card
          label="Unique Visitors"
          value={format_number(@stats.unique_visitors)}
          prev={@prev_stats && @prev_stats.unique_visitors}
          current={@stats.unique_visitors}
        />
        <.stat_card
          label="Sessions"
          value={format_number(@stats.sessions)}
          prev={@prev_stats && @prev_stats.sessions}
          current={@stats.sessions}
        />
        <.stat_card
          label="Bounce Rate"
          value={"#{@stats.bounce_rate}%"}
          prev={@prev_stats && @prev_stats.bounce_rate}
          current={@stats.bounce_rate}
          invert={true}
        />
        <.stat_card
          label="Avg Duration"
          value={format_duration(@stats.avg_duration)}
          prev={@prev_stats && @prev_stats.avg_duration}
          current={@stats.avg_duration}
        />
      </div>

      <%!-- Time-series Chart --%>
      <div
        class="bg-white rounded-lg shadow p-5 mb-6"
        id="timeseries-hook"
        phx-hook="TimeseriesChart"
      >
        <div style="height: 280px; position: relative;">
          <canvas></canvas>
        </div>
      </div>

      <%!-- Data Cards Grid --%>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <.data_card
          title="Top Pages"
          link={~p"/dashboard/sites/#{@site.id}/pages"}
          empty={@top_pages == []}
        >
          <div :for={row <- @top_pages} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4" title={row["url_path"]}>
              {row["url_path"]}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["pageviews"])}
            </span>
          </div>
        </.data_card>

        <.data_card
          title="Top Sources"
          link={~p"/dashboard/sites/#{@site.id}/sources"}
          empty={@top_sources == []}
        >
          <div :for={row <- @top_sources} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4">
              {row["referrer_domain"] || "Direct"}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["pageviews"])}
            </span>
          </div>
        </.data_card>

        <.data_card
          title="Top States"
          link={~p"/dashboard/sites/#{@site.id}/geo"}
          empty={@top_regions == []}
        >
          <div :for={row <- @top_regions} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4">
              {region_display(row)}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["unique_visitors"])}
            </span>
          </div>
        </.data_card>

        <.data_card
          title="Top Browsers"
          link={~p"/dashboard/sites/#{@site.id}/devices"}
          empty={@top_browsers == []}
        >
          <div :for={row <- @top_browsers} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4">
              {row["name"] || "Unknown"}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["unique_visitors"])}
            </span>
          </div>
        </.data_card>

        <.data_card
          title="Top OS"
          link={~p"/dashboard/sites/#{@site.id}/devices"}
          empty={@top_os == []}
        >
          <div :for={row <- @top_os} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4">
              {row["name"] || "Unknown"}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["unique_visitors"])}
            </span>
          </div>
        </.data_card>

        <.data_card
          title="Entry Pages"
          link={~p"/dashboard/sites/#{@site.id}/entry-exit"}
          empty={@entry_pages == []}
        >
          <div :for={row <- @entry_pages} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4 font-mono" title={row["url_path"]}>
              {row["url_path"]}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["entries"])}
            </span>
          </div>
        </.data_card>

        <.data_card
          title="Realtime"
          link={~p"/dashboard/sites/#{@site.id}/realtime"}
          empty={false}
        >
          <div class="flex flex-col items-center justify-center py-4">
            <div class="text-4xl font-bold text-gray-900">{@live_visitors}</div>
            <div class="text-sm text-gray-500 mt-1">active visitors</div>
          </div>
        </.data_card>
      </div>

      <%!-- Visitor Map --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
        <div class="bg-white rounded-lg shadow p-5">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-sm font-medium text-gray-500">Visitor Map</h3>
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/map"}
              class="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
            >
              View details &rarr;
            </.link>
          </div>
          <div
            id="map-hook"
            phx-hook="BubbleMap"
          >
            <div style="height: 300px; position: relative;">
              <canvas></canvas>
            </div>
          </div>
        </div>

        <%!-- Timezone Distribution --%>
        <div class="bg-white rounded-lg shadow p-5">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-sm font-medium text-gray-500">Top Timezones</h3>
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/map"}
              class="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
            >
              View all &rarr;
            </.link>
          </div>
          <div
            id="tz-hook"
            phx-hook="BarChart"
          >
            <div style={"height: #{max(length(@timezones) * 32, 100)}px; position: relative;"}>
              <canvas></canvas>
            </div>
          </div>
        </div>
      </div>

      <%!-- Analytics Navigation --%>
      <div class="mt-6 bg-white rounded-lg shadow p-5">
        <h3 class="text-sm font-medium text-gray-500 mb-3">Analytics</h3>
        <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-6 gap-2">
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/pages"} label="Pages" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/entry-exit"} label="Entry / Exit" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/transitions"} label="Transitions" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/sources"} label="Sources" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/attribution"} label="Attribution" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/geo"} label="Geography" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/map"} label="Visitor Map" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/devices"} label="Devices" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/visitor-log"} label="Visitor Log" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/search"} label="Site Search" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/cohort"} label="Cohort Retention" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/realtime"} label="Realtime" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/network"} label="Network" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/goals"} label="Goals" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/funnels"} label="Funnels" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/campaigns"} label="Campaigns" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/ecommerce"} label="Ecommerce" />
          <.nav_link to={~p"/dashboard/sites/#{@site.id}/exports"} label="Exports" />
        </div>
      </div>
    </div>
    """
  end

  # -- Components --

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class="flex items-center justify-center px-3 py-2 text-sm font-medium text-gray-700 bg-gray-50 rounded-lg hover:bg-indigo-50 hover:text-indigo-700 transition-colors border border-gray-200"
    >
      {@label}
    </.link>
    """
  end

  defp stat_card(assigns) do
    assigns =
      assigns
      |> Map.put_new(:prev, nil)
      |> Map.put_new(:current, nil)
      |> Map.put_new(:invert, false)

    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <dt class="text-sm font-medium text-gray-500 truncate">{@label}</dt>
      <dd class="mt-1 text-2xl font-bold text-gray-900">{@value}</dd>
      <dd :if={@prev != nil} class="mt-1">
        <% delta = compute_delta(@current, @prev, @invert) %>
        <span class={[
          "text-xs font-medium",
          if(delta.direction == :up, do: "text-green-600", else: ""),
          if(delta.direction == :down, do: "text-red-600", else: ""),
          if(delta.direction == :flat, do: "text-gray-400", else: "")
        ]}>
          {delta.label}
        </span>
        <span class="text-xs text-gray-400 ml-1">vs prior</span>
      </dd>
    </div>
    """
  end

  defp data_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow overflow-hidden">
      <div class="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
        <h3 class="font-semibold text-gray-900">{@title}</h3>
        <.link navigate={@link} class="text-xs text-indigo-600 hover:text-indigo-800 font-medium">
          View all &rarr;
        </.link>
      </div>
      <div class="px-5 py-2 divide-y divide-gray-50">
        <div :if={@empty} class="py-6 text-center text-sm text-gray-400">
          No data yet
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp compute_delta(current, prev, invert) when is_number(current) and is_number(prev) do
    if prev == 0 do
      if current > 0,
        do: %{label: "+100%", direction: if(invert, do: :down, else: :up)},
        else: %{label: "0%", direction: :flat}
    else
      pct = Float.round((current - prev) / prev * 100, 1)

      direction =
        cond do
          pct > 0 -> if(invert, do: :down, else: :up)
          pct < 0 -> if(invert, do: :up, else: :down)
          true -> :flat
        end

      sign = if pct > 0, do: "+", else: ""
      %{label: "#{sign}#{pct}%", direction: direction}
    end
  end

  defp compute_delta(_, _, _), do: %{label: "", direction: :flat}

  defp to_num(n) when is_integer(n), do: n
  defp to_num(n) when is_float(n), do: trunc(n)

  defp to_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_num(_), do: 0

  defp to_float(n) when is_float(n), do: n
  defp to_float(n) when is_integer(n), do: n * 1.0

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(_), do: "0m 0s"

  defp format_number(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when is_integer(n) and n >= 10_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n) when is_float(n), do: format_number(trunc(n))
  defp format_number(n) when is_binary(n), do: n
  defp format_number(_), do: "0"

  defp short_tz(tz) when is_binary(tz) do
    case String.split(tz, "/") do
      [_, city | _] -> String.replace(city, "_", " ")
      _ -> tz
    end
  end

  defp short_tz(_), do: "Unknown"

  defp location_label(loc) do
    city = loc["ip_city"] || ""
    region = loc["ip_region_name"] || ""
    country = loc["ip_country"] || ""
    [city, region, country] |> Enum.reject(&(&1 == "")) |> Enum.join(", ")
  end

  defp region_display(row) do
    region = row["ip_region_name"] || ""
    country = row["ip_country"] || ""

    cond do
      region != "" && country != "" -> "#{region}, #{country}"
      region != "" -> region
      true -> "Unknown"
    end
  end
end
