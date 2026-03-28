defmodule SpectabasWeb.Dashboard.SourcesLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent

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
      {:ok,
       socket
       |> assign(:page_title, "Sources - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> assign(:tab, "referrers")
       |> load_sources()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_sources()}
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:tab, tab)
     |> load_sources()}
  end

  defp load_sources(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns

    sources =
      case Analytics.top_sources(site, user, range_to_atom(range)) do
        {:ok, sources} -> sources
        _ -> []
      end

    assign(socket, :sources, sources)
  end

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Sources"
      page_description="Where your visitors come from — referrer domains and UTM parameters."
      active="sources"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Traffic Sources</h1>
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

        <div class="mb-6 flex gap-2">
          <button
            :for={
              {id, label} <- [
                {"referrers", "Referrers"},
                {"utm_source", "UTM Source"},
                {"utm_medium", "UTM Medium"}
              ]
            }
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

        <div class="bg-white rounded-lg shadow overflow-hidden">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Source
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Pageviews
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Sessions
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@sources == []}>
                <td colspan="3" class="px-6 py-8 text-center text-gray-500">
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
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {Map.get(source, "pageviews", 0)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {Map.get(source, "sessions", 0)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp source_name(source, "referrers"), do: Map.get(source, "referrer_domain", "Direct / None")
  defp source_name(source, "utm_source"), do: Map.get(source, "utm_source", "(none)")
  defp source_name(source, "utm_medium"), do: Map.get(source, "utm_medium", "(none)")
  defp source_name(source, _), do: Map.get(source, "referrer_domain", "Direct / None")

  defp source_link(site_id, source, "referrers") do
    domain = Map.get(source, "referrer_domain", "")

    ~p"/dashboard/sites/#{site_id}/visitor-log?filter_field=referrer_domain&filter_value=#{domain}"
  end

  defp source_link(site_id, source, "utm_source") do
    val = Map.get(source, "utm_source", "")
    ~p"/dashboard/sites/#{site_id}/visitor-log?filter_field=utm_source&filter_value=#{val}"
  end

  defp source_link(site_id, source, "utm_medium") do
    val = Map.get(source, "utm_medium", "")
    ~p"/dashboard/sites/#{site_id}/visitor-log?filter_field=utm_medium&filter_value=#{val}"
  end

  defp source_link(site_id, _source, _) do
    ~p"/dashboard/sites/#{site_id}/visitor-log"
  end
end
