defmodule SpectabasWeb.Dashboard.SiteLive do
  use SpectabasWeb, :live_view

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

      {:ok,
       socket
       |> assign(:page_title, site.name)
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
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
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_stats()}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp load_stats(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_atom(range)

    stats =
      case Analytics.overview_stats(site, user, period) do
        {:ok, s} ->
          %{
            pageviews: s["pageviews"] || 0,
            unique_visitors: s["unique_visitors"] || 0,
            sessions: s["total_sessions"] || 0,
            bounce_rate: s["bounce_rate"] || 0.0,
            avg_duration: s["avg_duration"] || 0
          }

        _ ->
          %{pageviews: 0, unique_visitors: 0, sessions: 0, bounce_rate: 0.0, avg_duration: 0}
      end

    top_pages = safe_query(fn -> Analytics.top_pages(site, user, period) end, 5)
    top_sources = safe_query(fn -> Analytics.top_sources(site, user, period) end, 5)
    top_countries = safe_query(fn -> Analytics.top_countries_summary(site, user, period) end, 5)
    top_devices = safe_query(fn -> Analytics.top_devices(site, user, period) end, 5)

    live_visitors =
      case Analytics.realtime_visitors(site) do
        {:ok, count} -> count
        _ -> 0
      end

    socket
    |> assign(:stats, stats)
    |> assign(:live_visitors, live_visitors)
    |> assign(:top_pages, top_pages)
    |> assign(:top_sources, top_sources)
    |> assign(:top_countries, top_countries)
    |> assign(:top_devices, top_devices)
  end

  defp safe_query(fun, limit) do
    case fun.() do
      {:ok, rows} when is_list(rows) -> Enum.take(rows, limit)
      _ -> []
    end
  end

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  defp range_label("24h"), do: "Today"
  defp range_label("7d"), do: "Last 7 days"
  defp range_label("30d"), do: "Last 30 days"
  defp range_label(_), do: "Last 7 days"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
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
        <div class="flex items-center gap-4">
          <div class="flex items-center gap-2 bg-green-50 text-green-700 px-3 py-1.5 rounded-full text-sm font-medium">
            <span class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></span>
            {@live_visitors} online now
          </div>
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

      <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
        <.stat_card label="Pageviews" value={format_number(@stats.pageviews)} />
        <.stat_card label="Unique Visitors" value={format_number(@stats.unique_visitors)} />
        <.stat_card label="Sessions" value={format_number(@stats.sessions)} />
        <.stat_card label="Bounce Rate" value={"#{@stats.bounce_rate}%"} />
        <.stat_card label="Avg Duration" value={format_duration(@stats.avg_duration)} />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <%!-- Top Pages --%>
        <.data_card
          title="Top Pages"
          period={range_label(@date_range)}
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

        <%!-- Top Sources --%>
        <.data_card
          title="Top Sources"
          period={range_label(@date_range)}
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

        <%!-- Top Countries --%>
        <.data_card
          title="Top Countries"
          period={range_label(@date_range)}
          link={~p"/dashboard/sites/#{@site.id}/geo"}
          empty={@top_countries == []}
        >
          <div :for={row <- @top_countries} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4">
              {country_display(row)}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["unique_visitors"])}
            </span>
          </div>
        </.data_card>

        <%!-- Top Devices --%>
        <.data_card
          title="Top Devices"
          period={range_label(@date_range)}
          link={~p"/dashboard/sites/#{@site.id}/devices"}
          empty={@top_devices == []}
        >
          <div :for={row <- @top_devices} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4">
              {device_display(row)}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["pageviews"])}
            </span>
          </div>
        </.data_card>

        <%!-- Realtime --%>
        <.data_card
          title="Realtime"
          period="Last 5 minutes"
          link={~p"/dashboard/sites/#{@site.id}/realtime"}
          empty={false}
        >
          <div class="flex flex-col items-center justify-center py-4">
            <div class="text-4xl font-bold text-gray-900">{@live_visitors}</div>
            <div class="text-sm text-gray-500 mt-1">active visitors</div>
          </div>
        </.data_card>

        <%!-- Entry Pages (top pages by unique visitors, different angle) --%>
        <.data_card
          title="Top Pages by Visitors"
          period={range_label(@date_range)}
          link={~p"/dashboard/sites/#{@site.id}/pages"}
          empty={@top_pages == []}
        >
          <div :for={row <- @top_pages} class="flex items-center justify-between py-2">
            <span class="text-sm text-gray-800 truncate mr-4" title={row["url_path"]}>
              {row["url_path"]}
            </span>
            <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
              {format_number(row["unique_visitors"])} visitors
            </span>
          </div>
        </.data_card>
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <dt class="text-sm font-medium text-gray-500 truncate">{@label}</dt>
      <dd class="mt-1 text-2xl font-bold text-gray-900">{@value}</dd>
    </div>
    """
  end

  defp data_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow overflow-hidden">
      <div class="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
        <div>
          <h3 class="font-semibold text-gray-900">{@title}</h3>
          <p class="text-xs text-gray-400 mt-0.5">{@period}</p>
        </div>
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

  defp country_display(row) do
    name = row["ip_country_name"] || ""
    code = row["ip_country"] || ""
    if name != "", do: name, else: if(code != "", do: code, else: "Unknown")
  end

  defp device_display(row) do
    browser = row["browser"] || ""
    os = row["os"] || ""
    device = row["device_type"] || ""

    parts = [browser, os, device] |> Enum.reject(&(&1 == "")) |> Enum.take(2)
    if parts == [], do: "Unknown", else: Enum.join(parts, " / ")
  end
end
