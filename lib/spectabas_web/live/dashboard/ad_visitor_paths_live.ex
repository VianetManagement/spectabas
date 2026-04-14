defmodule SpectabasWeb.Dashboard.AdVisitorPathsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Ad Visitor Paths — page sequences for ad traffic, segmented by conversion outcome."

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
      socket =
        socket
        |> assign(:page_title, "Ad Visitor Paths - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:view, "all")
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("change_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, :view, view)}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_data() |> assign(:loading, false)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    paths =
      case Analytics.ad_visitor_paths(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    bounces =
      case Analytics.ad_bounce_pages(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    total_sessions = Enum.reduce(paths, 0, fn p, acc -> acc + to_num(p["visitors"]) end)
    total_converters = Enum.reduce(paths, 0, fn p, acc -> acc + to_num(p["converters"]) end)
    total_bounces = Enum.reduce(bounces, 0, fn b, acc -> acc + to_num(b["bounces"]) end)

    socket
    |> assign(:paths, paths)
    |> assign(:bounces, bounces)
    |> assign(:total_sessions, total_sessions)
    |> assign(:total_converters, total_converters)
    |> assign(:total_bounces, total_bounces)
    |> assign(:has_data, paths != [] || bounces != [])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Ad Visitor Paths"
      page_description="Page sequences for ad traffic — what paths lead to conversion vs bounce."
      active="ad-visitor-paths"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Ad Visitor Paths</h1>
          <div class="flex gap-2">
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={{id, label} <- [{"all", "All Paths"}, {"bounces", "Bounce Pages"}]}
                phx-click="change_view"
                phx-value-view={id}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
                  if(@view == id,
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

        <%= if @loading do %>
          <div class="bg-white rounded-lg shadow p-12 text-center">
            <div class="inline-flex items-center gap-3 text-gray-600">
              <svg class="animate-spin h-5 w-5 text-indigo-600" viewBox="0 0 24 24" fill="none">
                <circle
                  class="opacity-25"
                  cx="12"
                  cy="12"
                  r="10"
                  stroke="currentColor"
                  stroke-width="4"
                />
                <path
                  class="opacity-75"
                  fill="currentColor"
                  d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
                />
              </svg>
              <span class="text-sm">Loading...</span>
            </div>
          </div>
        <% else %>
          <div :if={!@has_data} class="bg-white rounded-lg shadow p-12 text-center">
            <p class="text-gray-500">
              No ad visitor path data yet. Paths will appear as visitors arrive from ad clicks.
            </p>
          </div>

          <div :if={@has_data}>
            <div class="grid grid-cols-3 gap-4 mb-6">
              <div class="bg-white rounded-lg shadow p-4">
                <dt class="text-xs font-medium text-gray-500">Ad Sessions</dt>
                <dd class="mt-1 text-2xl font-bold text-gray-900">
                  {format_number(@total_sessions)}
                </dd>
              </div>
              <div class="bg-white rounded-lg shadow p-4">
                <dt class="text-xs font-medium text-gray-500">Converted</dt>
                <dd class="mt-1 text-2xl font-bold text-green-600">
                  {format_number(@total_converters)}
                </dd>
                <dd :if={@total_sessions > 0} class="text-xs text-gray-400">
                  {Float.round(@total_converters / @total_sessions * 100, 1)}%
                </dd>
              </div>
              <div class="bg-white rounded-lg shadow p-4">
                <dt class="text-xs font-medium text-gray-500">Bounced</dt>
                <dd class="mt-1 text-2xl font-bold text-red-500">{format_number(@total_bounces)}</dd>
              </div>
            </div>

            <%!-- Page Paths --%>
            <div :if={@view == "all"} class="bg-white rounded-lg shadow overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      Page Path
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Converted
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Conv Rate
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :for={path <- @paths} class="hover:bg-gray-50">
                    <td class="px-4 py-3 text-sm text-gray-900 font-mono">
                      <span class="text-xs">{path["journey"]}</span>
                    </td>
                    <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(path["visitors"]))}
                    </td>
                    <td class="px-4 py-3 text-sm text-green-600 text-right tabular-nums">
                      {format_number(to_num(path["converters"]))}
                    </td>
                    <td class="px-4 py-3 text-sm text-right tabular-nums">
                      <span class={
                        if parse_float(path["conversion_rate"]) > 5,
                          do: "text-green-600 font-bold",
                          else: "text-gray-600"
                      }>
                        {path["conversion_rate"]}%
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Bounce Pages --%>
            <div :if={@view == "bounces"} class="bg-white rounded-lg shadow overflow-x-auto">
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      Landing Page
                    </th>
                    <th class="px-4 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      Platform
                    </th>
                    <th class="px-4 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Bounces
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :for={b <- @bounces} class="hover:bg-gray-50">
                    <td class="px-4 py-3 text-sm font-mono text-gray-900">{b["landing_page"]}</td>
                    <td class="px-4 py-3 text-sm text-gray-600">{platform_label(b["platform"])}</td>
                    <td class="px-4 py-3 text-sm text-red-600 text-right tabular-nums font-bold">
                      {format_number(to_num(b["bounces"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p class="text-xs text-gray-500 mt-3">
              Shows the most common page sequences (first 5 pages) for visitors who arrived via ad clicks. Compare converting vs bouncing paths to optimize landing pages.
            </p>
          </div>
        <% end %>
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

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label(p), do: p
end
