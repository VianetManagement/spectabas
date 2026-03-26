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

    stats =
      case Analytics.overview_stats(site, user, range_to_atom(range)) do
        {:ok, stats} -> stats
        _ -> %{pageviews: 0, unique_visitors: 0, sessions: 0, bounce_rate: 0.0, avg_duration: 0}
      end

    live_visitors =
      case Analytics.realtime_visitors(site) do
        {:ok, count} -> count
        _ -> 0
      end

    socket
    |> assign(:stats, stats)
    |> assign(:live_visitors, live_visitors)
  end

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 class="text-2xl font-bold text-gray-900">{@site.name}</h1>
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
        <.stat_card label="Pageviews" value={@stats.pageviews} />
        <.stat_card label="Unique Visitors" value={@stats.unique_visitors} />
        <.stat_card label="Sessions" value={@stats.sessions} />
        <.stat_card label="Bounce Rate" value={"#{@stats.bounce_rate}%"} />
        <.stat_card label="Avg Duration" value={format_duration(@stats.avg_duration)} />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/pages"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-2">Top Pages</h3>
          <p class="text-sm text-gray-500">View page analytics</p>
        </.link>
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/sources"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-2">Sources</h3>
          <p class="text-sm text-gray-500">Where visitors come from</p>
        </.link>
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/geo"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-2">Geography</h3>
          <p class="text-sm text-gray-500">Visitor locations</p>
        </.link>
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/devices"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-2">Devices</h3>
          <p class="text-sm text-gray-500">Browsers, OS, device types</p>
        </.link>
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/realtime"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-2">Realtime</h3>
          <p class="text-sm text-gray-500">Live visitor feed</p>
        </.link>
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}/settings"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-2">Settings</h3>
          <p class="text-sm text-gray-500">Configure site tracking</p>
        </.link>
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

  defp format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(_), do: "0m 0s"
end
