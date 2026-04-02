defmodule SpectabasWeb.Dashboard.AdChurnLive do
  use SpectabasWeb, :live_view

  @moduledoc "Ad-to-Churn — which ad campaigns bring customers who churn vs stick."

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
       |> assign(:page_title, "Ad-to-Churn - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "90d")
       |> assign(:group_by, "platform")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  def handle_event("change_group", %{"group" => group}, socket) do
    {:noreply, socket |> assign(:group_by, group) |> load_data()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, group_by: group} = socket.assigns
    period = range_to_period(range)

    rows =
      case Analytics.ad_churn_by_campaign(site, user, period, group_by: group) do
        {:ok, data} -> data
        _ -> []
      end

    summary =
      case Analytics.ad_churn_summary(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    ad_summary = Enum.find(summary, %{}, fn r -> r["source_type"] == "ad" end)
    organic_summary = Enum.find(summary, %{}, fn r -> r["source_type"] == "organic" end)

    socket
    |> assign(:rows, rows)
    |> assign(:ad_summary, ad_summary)
    |> assign(:organic_summary, organic_summary)
    |> assign(:has_data, rows != [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Ad-to-Churn"
      page_description="Which ad campaigns bring customers who stick vs churn."
      active="ad-churn"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Ad-to-Churn Correlation</h1>
          <div class="flex gap-2">
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={{id, label} <- [{"platform", "By Platform"}, {"campaign", "By Campaign"}]}
                phx-click="change_group"
                phx-value-group={id}
                class={["px-2.5 py-1 text-xs font-medium rounded-md",
                  if(@group_by == id, do: "bg-white shadow text-gray-900", else: "text-gray-600 hover:text-gray-900")]}
              >
                {label}
              </button>
            </nav>
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
        </div>

        <div :if={!@has_data} class="bg-white rounded-lg shadow p-12 text-center">
          <p class="text-gray-500">Not enough data yet. Churn analysis requires ad visitors with repeat sessions over at least 28 days.</p>
        </div>

        <div :if={@has_data}>
          <%!-- Comparison cards --%>
          <div class="grid grid-cols-2 gap-4 mb-6">
            <div class="bg-white rounded-lg shadow p-5">
              <h3 class="text-xs font-semibold text-gray-500 uppercase mb-2">Ad Traffic Churn</h3>
              <dd class={"text-3xl font-bold #{churn_color(parse_float(@ad_summary["churn_rate"]))}"}>
                {@ad_summary["churn_rate"] || "0"}%
              </dd>
              <dd class="text-xs text-gray-400 mt-1">
                {format_number(to_num(@ad_summary["churned"]))} of {format_number(to_num(@ad_summary["total_visitors"]))} visitors
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-5">
              <h3 class="text-xs font-semibold text-gray-500 uppercase mb-2">Organic Traffic Churn</h3>
              <dd class={"text-3xl font-bold #{churn_color(parse_float(@organic_summary["churn_rate"]))}"}>
                {@organic_summary["churn_rate"] || "0"}%
              </dd>
              <dd class="text-xs text-gray-400 mt-1">
                {format_number(to_num(@organic_summary["churned"]))} of {format_number(to_num(@organic_summary["total_visitors"]))} visitors
              </dd>
            </div>
          </div>

          <%!-- Campaign table --%>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">{if @group_by == "platform", do: "Platform", else: "Campaign"}</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Visitors</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Churned</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Retained</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Purchased</th>
                  <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">Churn Rate</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={row <- @rows} class="hover:bg-gray-50">
                  <td class="px-4 py-3 text-sm font-medium text-gray-900">
                    {if @group_by == "platform", do: platform_label(row["platform"]), else: row["campaign"] || row["platform"] || "(none)"}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">{format_number(to_num(row["total_visitors"]))}</td>
                  <td class="px-4 py-3 text-sm text-red-600 text-right tabular-nums">{format_number(to_num(row["churned"]))}</td>
                  <td class="px-4 py-3 text-sm text-green-600 text-right tabular-nums">{format_number(to_num(row["retained"]))}</td>
                  <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">{format_number(to_num(row["purchased"]))}</td>
                  <td class="px-4 py-3 text-right">
                    <span class={"text-sm font-bold tabular-nums #{churn_color(parse_float(row["churn_rate"]))}"}>
                      {row["churn_rate"]}%
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p class="text-xs text-gray-500 mt-3">
            Churn = 50%+ decline in sessions over a 14-day window. Compares the most recent 14 days to the prior 14 days for each visitor who had activity in both periods. Lower churn rate = stickier customers.
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

  defp churn_color(rate) when rate >= 50, do: "text-red-600"
  defp churn_color(rate) when rate >= 25, do: "text-yellow-600"
  defp churn_color(_), do: "text-green-600"

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label(p), do: p
end
