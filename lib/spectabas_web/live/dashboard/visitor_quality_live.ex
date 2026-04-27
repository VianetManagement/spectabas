defmodule SpectabasWeb.Dashboard.VisitorQualityLive do
  use SpectabasWeb, :live_view

  @moduledoc "Visitor Quality Score — engagement scoring for ad traffic by platform/campaign."

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
        |> assign(:page_title, "Visitor Quality - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:group_by, "platform")
        |> assign(:loading, true)
        |> assign(:rows, [])
        |> assign(:has_data, false)
        |> assign(:total_visitors, 0)
        |> assign(:avg_score, 0)

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
      case Analytics.visitor_quality_by_source(site, user, period, group_by: group) do
        {:ok, data} -> data
        _ -> []
      end

    has_data = rows != []

    # Compute averages
    total_visitors = Enum.reduce(rows, 0, fn r, acc -> acc + to_num(r["visitors"]) end)

    avg_score =
      if total_visitors > 0 do
        weighted =
          Enum.reduce(rows, 0, fn r, acc ->
            acc + parse_float(r["quality_score"]) * to_num(r["visitors"])
          end)

        Float.round(weighted / total_visitors, 1)
      else
        0
      end

    socket
    |> assign(:rows, rows)
    |> assign(:has_data, has_data)
    |> assign(:total_visitors, total_visitors)
    |> assign(:avg_score, avg_score)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Visitor Quality"
      page_description="Engagement scoring for ad traffic — which platforms bring your best visitors."
      active="visitor-quality"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Visitor Quality Score</h1>
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

        <div :if={@loading} class="flex items-center justify-center py-12 text-gray-400">
          <.death_star_spinner class="w-8 h-8" />
        </div>

        <div :if={!@loading}>
          <div :if={!@has_data} class="bg-white rounded-lg shadow p-12 text-center">
            <p class="text-gray-500">
              No ad visitor data yet. Quality scores will appear as visitors arrive from ad clicks (gclid/msclkid/fbclid).
            </p>
          </div>

          <div :if={@has_data}>
            <div class="grid grid-cols-2 md:grid-cols-3 gap-4 mb-6">
              <div class="bg-white rounded-lg shadow p-4">
                <dt class="text-xs font-medium text-gray-500">Avg Quality Score</dt>
                <dd class={"mt-1 text-3xl font-bold #{score_color(@avg_score)}"}>{@avg_score}</dd>
                <dd class="text-[10px] text-gray-400">out of 100</dd>
              </div>
              <div class="bg-white rounded-lg shadow p-4">
                <dt class="text-xs font-medium text-gray-500">Ad Visitors</dt>
                <dd class="mt-1 text-3xl font-bold text-gray-900">
                  {format_number(@total_visitors)}
                </dd>
              </div>
              <div class="bg-white rounded-lg shadow p-4">
                <dt class="text-xs font-medium text-gray-500">Score Components</dt>
                <dd class="mt-1 text-xs text-gray-500 space-y-0.5">
                  <div>Pages/session: 25pts</div>
                  <div>Duration: 25pts</div>
                  <div>Non-bounce: 20pts</div>
                  <div>Return visits: 15pts</div>
                  <div>High intent: 15pts</div>
                </dd>
              </div>
            </div>

            <div class="bg-white rounded-lg shadow overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      {if @group_by == "platform", do: "Platform", else: "Campaign"}
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Score
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Pages/Session
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Avg Duration
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Bounce Rate
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Return Rate
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      High Intent
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
                    <td class="px-4 py-3 text-right">
                      <div class="flex items-center justify-end gap-2">
                        <div class="w-16 bg-gray-200 rounded-full h-2">
                          <div
                            class={"h-2 rounded-full #{score_bar_color(parse_float(row["quality_score"]))}"}
                            style={"width: #{min(parse_float(row["quality_score"]), 100)}%"}
                          >
                          </div>
                        </div>
                        <span class={"text-sm font-bold tabular-nums w-8 text-right #{score_color(parse_float(row["quality_score"]))}"}>
                          {row["quality_score"]}
                        </span>
                      </div>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(row["visitors"]))}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {row["avg_pages"]}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {format_duration(parse_float(row["avg_duration_s"]))}
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {row["bounce_rate"]}%
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {row["return_rate"]}%
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-600 text-right tabular-nums">
                      {row["high_intent_pct"]}%
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p class="text-xs text-gray-500 mt-3">
              Quality score (0-100) measures ad visitor engagement: pages viewed, time on site, bounce rate, return visits, and visitor intent signals. Higher is better.
            </p>
          </div>
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

  defp score_color(score) when score >= 60, do: "text-green-600"
  defp score_color(score) when score >= 30, do: "text-yellow-600"
  defp score_color(_), do: "text-red-600"

  defp score_bar_color(score) when score >= 60, do: "bg-green-500"
  defp score_bar_color(score) when score >= 30, do: "bg-yellow-500"
  defp score_bar_color(_), do: "bg-red-500"

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
