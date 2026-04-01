defmodule SpectabasWeb.Dashboard.BuyerPatternsLive do
  use SpectabasWeb, :live_view

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
       |> assign(:page_title, "Buyer Patterns - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "30d")
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

    patterns =
      case Analytics.buyer_page_patterns(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    stats_rows =
      case Analytics.buyer_vs_nonbuyer_stats(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    buyer_stats = Enum.find(stats_rows, %{}, &(to_num(&1["is_buyer"]) == 1))
    nonbuyer_stats = Enum.find(stats_rows, %{}, &(to_num(&1["is_buyer"]) == 0))

    socket
    |> assign(:patterns, patterns)
    |> assign(:buyer_stats, buyer_stats)
    |> assign(:nonbuyer_stats, nonbuyer_stats)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Buyer Patterns"
      page_description="How buyer behavior differs from non-buyers."
      active="buyer-patterns"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-2xl font-bold text-gray-900">Buyer Patterns</h1>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7d"}, {"30d", "30d"}]}
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

        <%!-- Buyer vs Non-Buyer Comparison --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
          <div class="bg-white rounded-lg shadow p-6">
            <h3 class="text-sm font-semibold text-green-600 uppercase mb-4">Buyers</h3>
            <dl class="grid grid-cols-3 gap-4">
              <div>
                <dt class="text-xs text-gray-500">Avg Sessions</dt>
                <dd class="text-2xl font-bold text-gray-900">
                  {@buyer_stats["avg_sessions"] || "0"}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Avg Pages</dt>
                <dd class="text-2xl font-bold text-gray-900">
                  {@buyer_stats["avg_pages"] || "0"}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Avg Duration</dt>
                <dd class="text-2xl font-bold text-gray-900">
                  {format_duration(to_num(@buyer_stats["avg_duration"]))}
                </dd>
              </div>
            </dl>
          </div>
          <div class="bg-white rounded-lg shadow p-6">
            <h3 class="text-sm font-semibold text-gray-500 uppercase mb-4">Non-Buyers</h3>
            <dl class="grid grid-cols-3 gap-4">
              <div>
                <dt class="text-xs text-gray-500">Avg Sessions</dt>
                <dd class="text-2xl font-bold text-gray-900">
                  {@nonbuyer_stats["avg_sessions"] || "0"}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Avg Pages</dt>
                <dd class="text-2xl font-bold text-gray-900">
                  {@nonbuyer_stats["avg_pages"] || "0"}
                </dd>
              </div>
              <div>
                <dt class="text-xs text-gray-500">Avg Duration</dt>
                <dd class="text-2xl font-bold text-gray-900">
                  {format_duration(to_num(@nonbuyer_stats["avg_duration"]))}
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <%!-- Page Lift Analysis --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-lg font-semibold text-gray-900">Pages Where Buyers Over-Index</h2>
            <p class="text-sm text-gray-500 mt-1">
              "Lift" shows how much more likely buyers are to visit this page compared to non-buyers.
            </p>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Page</th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Buyer Visitors
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Non-Buyer Visitors
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">Lift</th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@patterns == []}>
                <td colspan="4" class="px-6 py-8 text-center text-gray-500">
                  Not enough buyer data for pattern analysis.
                </td>
              </tr>
              <tr :for={row <- @patterns} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-mono text-gray-900">{row["url_path"]}</td>
                <td class="px-6 py-4 text-sm text-green-600 text-right tabular-nums font-medium">
                  {format_number(to_num(row["buyer_visitors"]))}
                </td>
                <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                  {format_number(to_num(row["nonbuyer_visitors"]))}
                </td>
                <td class="px-6 py-4 text-right">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-bold",
                    lift_color(row["lift"])
                  ]}>
                    {row["lift"]}x
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp lift_color(lift) do
    l = parse_float(lift)

    cond do
      l >= 2.0 -> "bg-green-100 text-green-800"
      l >= 1.0 -> "bg-blue-100 text-blue-800"
      true -> "bg-gray-100 text-gray-600"
    end
  end

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(n) when is_number(n), do: n / 1
  defp parse_float(_), do: 0.0
end
