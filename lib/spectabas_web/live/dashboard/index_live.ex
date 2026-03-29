defmodule SpectabasWeb.Dashboard.IndexLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Analytics}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    sites = Accounts.accessible_sites(user)

    site_stats =
      Enum.reduce(sites, %{}, fn site, acc ->
        tz = site.timezone || "UTC"
        date_range = Analytics.period_to_date_range(:today, tz)

        stats =
          case Analytics.overview_stats(site, user, date_range) do
            {:ok, s} ->
              %{
                pageviews: to_num(s["pageviews"]),
                visitors: to_num(s["unique_visitors"])
              }

            _ ->
              %{pageviews: 0, visitors: 0}
          end

        Map.put(acc, site.id, stats)
      end)

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:sites, sites)
     |> assign(:site_stats, site_stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold text-gray-900">Your Sites</h1>
        <.link
          :if={@current_scope.user.role in [:superadmin, :admin]}
          navigate={~p"/admin/sites"}
          class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
        >
          + Add Site
        </.link>
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
            <span :if={site.dns_verified} class="text-green-500 text-sm font-medium">
              Verified
            </span>
            <span :if={!site.dns_verified} class="text-yellow-500 text-sm font-medium">
              Pending
            </span>
          </div>
          <p class="text-sm text-gray-500 truncate mb-4">{site.domain}</p>
          <div class="flex items-center gap-6">
            <div>
              <span class="text-3xl font-bold text-indigo-600">
                {format_number(get_stat(@site_stats, site.id, :pageviews))}
              </span>
              <span class="text-sm text-gray-500 ml-1">pageviews</span>
            </div>
            <div>
              <span class="text-3xl font-bold text-emerald-600">
                {format_number(get_stat(@site_stats, site.id, :visitors))}
              </span>
              <span class="text-sm text-gray-500 ml-1">visitors</span>
            </div>
          </div>
          <p class="text-xs text-gray-400 mt-2">today</p>
        </.link>
      </div>
    </div>
    """
  end

  defp get_stat(stats, site_id, key) do
    stats |> Map.get(site_id, %{}) |> Map.get(key, 0)
  end

  defp to_num(n) when is_integer(n), do: n

  defp to_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end

  defp to_num(_), do: 0

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)
end
