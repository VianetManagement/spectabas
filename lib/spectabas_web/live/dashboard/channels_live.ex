defmodule SpectabasWeb.Dashboard.ChannelsLive do
  @moduledoc "All Channels — traffic grouped by marketing channel with drill-down."

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  alias Spectabas.Analytics.ChannelClassifier
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "All Channels - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "7d")
       |> assign(:selected_channel, nil)
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  def handle_event("select_channel", %{"channel" => channel}, socket) do
    {:noreply, socket |> assign(:selected_channel, channel) |> load_data()}
  end

  def handle_event("back_to_channels", _params, socket) do
    {:noreply, socket |> assign(:selected_channel, nil)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, selected_channel: selected} = socket.assigns
    period = range_to_period(range)

    channels = safe_query(fn -> Analytics.channel_breakdown(site, user, period) end)

    detail =
      if selected do
        safe_query(fn -> Analytics.channel_detail(site, user, period, selected) end)
      else
        []
      end

    socket
    |> assign(:channels, channels)
    |> assign(:channel_detail, detail)
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

        <%!-- Channel Detail View --%>
        <div :if={@selected_channel} class="mb-6">
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
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :if={@channel_detail == []}>
                  <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                    No sources for this channel.
                  </td>
                </tr>
                <tr :for={src <- @channel_detail} class="hover:bg-gray-50">
                  <td class="px-6 py-4 text-sm text-indigo-600 font-medium">{src["source"]}</td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {src["pageviews"]}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {src["visitors"]}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {src["sessions"]}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Channels Overview --%>
        <div :if={!@selected_channel} class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Channel
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
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Sources
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :if={@channels == []}>
                <td colspan="5" class="px-6 py-8 text-center text-gray-500">
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
                  {ch["pageviews"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {ch["visitors"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {ch["sessions"]}
                </td>
                <td class="px-6 py-4 text-sm text-gray-500 text-right tabular-nums">
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
