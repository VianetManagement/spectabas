defmodule SpectabasWeb.Dashboard.IndexLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Analytics}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    sites = Accounts.accessible_sites(user)

    pageview_counts =
      Enum.reduce(sites, %{}, fn site, acc ->
        count =
          case Analytics.overview_stats(site, user, :today) do
            {:ok, %{pageviews: pv}} -> pv
            _ -> 0
          end

        Map.put(acc, site.id, count)
      end)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:sites, sites)
     |> assign(:pageview_counts, pageview_counts)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold text-gray-900">Your Sites</h1>
      </div>

      <div :if={@sites == []} class="text-center py-16 text-gray-500">
        <p class="text-lg">No sites yet.</p>
        <p class="mt-2">Ask an admin to grant you access to a site.</p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <.link
          :for={site <- @sites}
          navigate={~p"/dashboard/sites/#{site.id}"}
          class="block bg-white rounded-lg shadow hover:shadow-md transition-shadow p-6 border border-gray-200"
        >
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold text-gray-900 truncate">{site.name}</h2>
            <span :if={site.dns_verified} class="text-green-500 text-sm font-medium">Verified</span>
            <span :if={!site.dns_verified} class="text-yellow-500 text-sm font-medium">Pending</span>
          </div>
          <p class="text-sm text-gray-500 truncate mb-4">{site.domain}</p>
          <div class="flex items-baseline gap-2">
            <span class="text-3xl font-bold text-indigo-600">
              {Map.get(@pageview_counts, site.id, 0) |> format_number()}
            </span>
            <span class="text-sm text-gray-500">pageviews today</span>
          </div>
        </.link>
      </div>
    </div>
    """
  end

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)
end
