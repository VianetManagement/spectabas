defmodule SpectabasWeb.Dashboard.OrganicLiftLive do
  use SpectabasWeb, :live_view

  @moduledoc "Organic Lift — does ad spend correlate with higher organic/direct traffic?"

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Organic Lift - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "90d")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    timeseries =
      case Analytics.organic_lift_timeseries(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    comparison =
      case Analytics.organic_lift_comparison(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    high = Enum.find(comparison, %{}, fn r -> r["period_type"] == "high_spend" end)
    low = Enum.find(comparison, %{}, fn r -> r["period_type"] == "low_spend" end)

    # Calculate lift
    high_organic = parse_float(high["avg_organic_visitors"])
    low_organic = parse_float(low["avg_organic_visitors"])

    organic_lift =
      if low_organic > 0 do
        Float.round((high_organic - low_organic) / low_organic * 100, 1)
      else
        nil
      end

    # Max values for chart scaling
    max_visitors =
      timeseries
      |> Enum.reduce(0, fn d, acc ->
        max(acc, max(to_num(d["organic_visitors"]), to_num(d["direct_visitors"])))
      end)

    max_spend = Enum.reduce(timeseries, 0, fn d, acc -> max(acc, parse_float(d["ad_spend"])) end)

    socket
    |> assign(:timeseries, timeseries)
    |> assign(:high_spend, high)
    |> assign(:low_spend, low)
    |> assign(:organic_lift, organic_lift)
    |> assign(:max_visitors, max_visitors)
    |> assign(:max_spend, max_spend)
    |> assign(:has_data, timeseries != [] && max_spend > 0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Organic Lift"
      page_description="Does ad spend correlate with higher organic and direct traffic?"
      active="organic-lift"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Organic Lift</h1>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"30d", "30d"}, {"90d", "90d"}]}
              phx-click="change_range"
              phx-value-range={elem(r, 0)}
              class={["px-2.5 py-1 text-xs font-medium rounded-md",
                if(@date_range == elem(r, 0), do: "bg-white shadow text-gray-900", else: "text-gray-600 hover:text-gray-900")]}
            >
              {elem(r, 1)}
            </button>
          </nav>
        </div>

        <div :if={!@has_data} class="bg-white rounded-lg shadow p-12 text-center">
          <p class="text-gray-500">Needs ad spend data to compare with organic traffic. Connect an ad platform and wait for spend data to sync.</p>
        </div>

        <div :if={@has_data}>
          <%!-- Lift insight --%>
          <div :if={@organic_lift} class={[
            "rounded-lg shadow p-5 mb-6",
            if(@organic_lift > 0, do: "bg-green-50", else: "bg-yellow-50")
          ]}>
            <p class={["text-lg font-bold", if(@organic_lift > 0, do: "text-green-800", else: "text-yellow-800")]}>
              Organic traffic is {@organic_lift}% {if @organic_lift > 0, do: "higher", else: "lower"} on high-spend days
            </p>
            <p class="text-sm text-gray-600 mt-1">
              Comparing days with above-median ad spend vs below-median. Correlation, not causation — but a positive lift suggests ads have a halo effect on organic discovery.
            </p>
          </div>

          <%!-- Comparison cards --%>
          <div class="grid grid-cols-2 gap-4 mb-6">
            <div class="bg-white rounded-lg shadow p-5">
              <h3 class="text-xs font-semibold text-gray-500 uppercase mb-2">High Spend Days</h3>
              <div class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <span class="text-gray-500">Days</span>
                  <span class="font-bold text-gray-900">{@high_spend["days"] || 0}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Avg Daily Spend</span>
                  <span class="font-bold text-gray-900">{@site.currency} {format_money(@high_spend["avg_daily_spend"])}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Avg Organic Visitors</span>
                  <span class="font-bold text-green-600">{@high_spend["avg_organic_visitors"] || 0}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Avg Direct Visitors</span>
                  <span class="font-bold text-indigo-600">{@high_spend["avg_direct_visitors"] || 0}</span>
                </div>
              </div>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <h3 class="text-xs font-semibold text-gray-500 uppercase mb-2">Low Spend Days</h3>
              <div class="space-y-2 text-sm">
                <div class="flex justify-between">
                  <span class="text-gray-500">Days</span>
                  <span class="font-bold text-gray-900">{@low_spend["days"] || 0}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Avg Daily Spend</span>
                  <span class="font-bold text-gray-900">{@site.currency} {format_money(@low_spend["avg_daily_spend"])}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Avg Organic Visitors</span>
                  <span class="font-bold text-green-600">{@low_spend["avg_organic_visitors"] || 0}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-500">Avg Direct Visitors</span>
                  <span class="font-bold text-indigo-600">{@low_spend["avg_direct_visitors"] || 0}</span>
                </div>
              </div>
            </div>
          </div>

          <%!-- Daily timeseries table --%>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="text-sm font-semibold text-gray-700">Daily Breakdown</h3>
            </div>
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Date</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Ad Spend</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Organic Visitors</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Direct Visitors</th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">Spend Level</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={d <- @timeseries} class="hover:bg-gray-50">
                  <td class="px-4 py-2 text-sm text-gray-500">{d["day"]}</td>
                  <td class="px-4 py-2 text-sm text-gray-900 text-right tabular-nums">
                    {if parse_float(d["ad_spend"]) > 0, do: "#{@site.currency} #{format_money(d["ad_spend"])}", else: "--"}
                  </td>
                  <td class="px-4 py-2 text-sm text-green-600 text-right tabular-nums font-medium">
                    {format_number(to_num(d["organic_visitors"]))}
                  </td>
                  <td class="px-4 py-2 text-sm text-indigo-600 text-right tabular-nums">
                    {format_number(to_num(d["direct_visitors"]))}
                  </td>
                  <td class="px-4 py-2">
                    <span :if={parse_float(d["ad_spend"]) > 0} class={[
                      "px-2 py-0.5 rounded text-[10px] font-medium",
                      if(parse_float(d["ad_spend"]) >= @max_spend * 0.5,
                        do: "bg-violet-100 text-violet-700",
                        else: "bg-gray-100 text-gray-500")
                    ]}>
                      {if parse_float(d["ad_spend"]) >= @max_spend * 0.5, do: "High", else: "Low"}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p class="text-xs text-gray-500 mt-3">
            Organic visitors = arrived via search engine referrer without ad click IDs. Direct visitors = no referrer and no ad click. High/low split at median daily spend.
          </p>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(n) when is_number(n), do: n / 1
  defp parse_float(_), do: 0.0

  defp format_money(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 2)
      :error -> "0.00"
    end
  end

  defp format_money(n) when is_number(n), do: :erlang.float_to_binary(n / 1, decimals: 2)
  defp format_money(_), do: "0.00"
end
