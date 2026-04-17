defmodule SpectabasWeb.Dashboard.TimeToConvertLive do
  use SpectabasWeb, :live_view

  @moduledoc "Time to Convert — how long it takes ad visitors to purchase."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Time to Convert - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:group_by, "platform")
        |> assign(:loading, true)
        |> assign(:rows, [])
        |> assign(:distribution, [])
        |> assign(:max_bucket, 0)
        |> assign(:total_converters, 0)
        |> assign(:has_data, false)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("change_group", %{"group" => group}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:group_by, group) |> assign(:loading, true)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, group_by: group} = socket.assigns
    period = range_to_period(range)

    rows =
      case Analytics.time_to_convert_by_source(site, user, period, group_by: group) do
        {:ok, data} -> data
        _ -> []
      end

    distribution =
      case Analytics.time_to_convert_distribution(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    max_bucket = Enum.reduce(distribution, 0, fn d, acc -> max(acc, to_num(d["visitors"])) end)

    total_converters = Enum.reduce(rows, 0, fn r, acc -> acc + to_num(r["converters"]) end)

    socket
    |> assign(:rows, rows)
    |> assign(:distribution, distribution)
    |> assign(:max_bucket, max_bucket)
    |> assign(:total_converters, total_converters)
    |> assign(:has_data, rows != [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Time to Convert"
      page_description="How long it takes ad visitors to make a purchase."
      active="time-to-convert"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Time to Convert</h1>
          <div class="flex gap-2">
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={{id, label} <- [{"platform", "By Platform"}, {"campaign", "By Campaign"}]}
                phx-click="change_group"
                phx-value-group={id}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
                  if(@group_by == id,
                    do: "bg-white shadow text-gray-900",
                    else: "text-gray-600 hover:text-gray-900"
                  )
                ]}
              >
                {label}
              </button>
            </nav>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={r <- [{"7d", "7d"}, {"30d", "30d"}, {"90d", "90d"}]}
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

        <div :if={@loading} class="flex items-center justify-center py-12">
          <div class="animate-spin rounded-full h-8 w-8 border-b-2 border-indigo-600"></div>
        </div>

        <div :if={!@loading}>
          <div :if={!@has_data} class="bg-white rounded-lg shadow p-12 text-center">
            <p class="text-gray-500">
              No ad-driven conversions yet. Data will appear as visitors who arrive via ad clicks make purchases.
            </p>
          </div>

          <div :if={@has_data}>
            <%!-- Distribution histogram --%>
            <div class="bg-white rounded-lg shadow p-5 mb-6">
              <h2 class="text-sm font-semibold text-gray-900 mb-4">Conversion Speed Distribution</h2>
              <div class="space-y-2">
                <div :for={d <- @distribution} class="flex items-center gap-3">
                  <span class="text-xs text-gray-600 w-20 text-right shrink-0">{d["bucket"]}</span>
                  <div class="flex-1 bg-gray-100 rounded-full h-5 relative">
                    <div
                      class="bg-indigo-500 h-5 rounded-full flex items-center justify-end pr-2"
                      style={"width: #{if @max_bucket > 0, do: to_num(d["visitors"]) / @max_bucket * 100, else: 0}%"}
                    >
                      <span :if={to_num(d["visitors"]) > 0} class="text-[10px] text-white font-medium">
                        {format_number(to_num(d["visitors"]))}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
              <p class="text-xs text-gray-400 mt-3">
                {format_number(@total_converters)} total conversions from ad clicks
              </p>
            </div>

            <%!-- Per-source table --%>
            <div class="bg-white rounded-lg shadow overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      {if @group_by == "platform", do: "Platform", else: "Campaign"}
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Converters
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Avg Days
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Median Days
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Avg Sessions
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Median Sessions
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :for={row <- @rows} class="hover:bg-gray-50">
                    <td class="px-4 py-3 text-sm font-medium text-gray-900">
                      {if @group_by == "platform",
                        do: platform_label(row["platform"]),
                        else: row["campaign"] || "(none)"}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(row["converters"]))}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums font-bold">
                      {row["avg_days"]}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {row["median_days"]}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {row["avg_sessions"]}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {row["median_sessions"]}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p class="text-xs text-gray-500 mt-3">
              Measures the gap between a visitor's first ad click and their first purchase. Fewer days = more ready-to-buy traffic.
            </p>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label("pinterest_ads"), do: "Pinterest"
  defp platform_label("reddit_ads"), do: "Reddit"
  defp platform_label("tiktok_ads"), do: "TikTok"
  defp platform_label("twitter_ads"), do: "X / Twitter"
  defp platform_label("linkedin_ads"), do: "LinkedIn"
  defp platform_label("snapchat_ads"), do: "Snapchat"
  defp platform_label(p), do: p
end
