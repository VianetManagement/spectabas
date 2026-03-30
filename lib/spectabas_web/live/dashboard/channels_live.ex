defmodule SpectabasWeb.Dashboard.ChannelsLive do
  use SpectabasWeb, :live_view

  @moduledoc "All Channels — traffic grouped by marketing channel."

  alias Spectabas.{Accounts, Sites, Analytics}
  alias Spectabas.Analytics.ChannelClassifier
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers

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
       |> assign(:page_title, "Channels - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> load_channels()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_channels()}
  end

  defp load_channels(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns

    channels =
      case Analytics.channel_breakdown(site, user, range_to_period(range)) do
        {:ok, data} -> data
        _ -> []
      end

    assign(socket, :channels, channels)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="All Channels"
      page_description="Traffic grouped by marketing channel — search, social, direct, email, AI assistants, and more."
      active="channels"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">All Channels</h1>
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

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Channel
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Pageviews
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Visitors
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Sessions
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Sources
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@channels == []}>
                <td colspan="5" class="px-6 py-8 text-center text-gray-500">
                  No data for this period.
                </td>
              </tr>
              <tr :for={ch <- @channels} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/sources?tab=referrers"}
                    class="inline-flex items-center gap-2"
                  >
                    <span class={[
                      "inline-block px-2.5 py-0.5 rounded-full text-xs font-medium",
                      ChannelClassifier.channel_color(ch["channel"])
                    ]}>
                      {ch["channel"]}
                    </span>
                  </.link>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {ch["pageviews"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {ch["visitors"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right">
                  {ch["sessions"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-500 text-right">
                  {ch["sources"]}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
