defmodule SpectabasWeb.Dashboard.JourneysLive do
  @moduledoc "Visitor journey mapping — common multi-step navigation paths grouped by page type and outcome."

  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites}
  alias Spectabas.Analytics.JourneyMapper
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
      socket =
        socket
        |> assign(:page_title, "Visitor Journeys - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:loading, true)
        |> assign(:data, nil)

      if connected?(socket), do: send(self(), :load_data)

      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    data =
      case JourneyMapper.analyze(site, user, period) do
        {:ok, result} -> result
        _ -> %{converters: [], engaged: [], bounced: [], stats: %{}}
      end

    socket
    |> assign(:data, data)
    |> assign(:loading, false)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Visitor Journeys"
      page_description="Common paths visitors take, grouped by page type and outcome."
      active="journeys"
      live_visitors={0}
    >
      <div class="max-w-5xl mx-auto px-3 sm:px-6 lg:px-8 py-6">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Visitor Journeys</h1>
            <p class="text-sm text-gray-500 mt-1">
              Pages grouped by type using your configured content prefixes.
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7 days"}, {"30d", "30 days"}]}
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

        <%!-- Configuration hints --%>
        <%= if Enum.empty?(@site.scraper_content_prefixes || []) do %>
          <div class="bg-amber-50 border border-amber-200 text-amber-900 rounded-lg p-4 mb-6 text-sm">
            <span class="font-semibold">Configure content prefixes</span>
            in
            <.link navigate={~p"/dashboard/sites/#{@site.id}/settings"} class="underline">
              Site Settings
            </.link>
            to group URLs by page type (e.g. <span class="font-mono">/listings</span>
            → "Listings").
            Without this, individual URLs are used and patterns are harder to see.
          </div>
        <% end %>
        <%= if Enum.empty?(@site.journey_conversion_pages || []) do %>
          <div class="bg-blue-50 border border-blue-200 text-blue-900 rounded-lg p-4 mb-6 text-sm">
            <span class="font-semibold">Configure conversion pages</span>
            in
            <.link navigate={~p"/dashboard/sites/#{@site.id}/settings"} class="underline">
              Site Settings → Visitor Journeys
            </.link>
            to see which paths lead to conversions (e.g. <span class="font-mono">/contact</span>).
          </div>
        <% end %>

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
              <span class="text-sm">Analyzing visitor journeys...</span>
            </div>
          </div>
        <% else %>
          <% stats = @data.stats || %{} %>

          <%!-- Stats cards --%>
          <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-8">
            <div class="bg-white rounded-lg shadow p-4">
              <dt class="text-xs font-medium text-gray-500">Total Sessions</dt>
              <dd class="mt-1 text-xl font-bold text-gray-900">
                {format_number(stats[:total_sessions] || 0)}
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <dt class="text-xs font-medium text-gray-500">Multi-Page</dt>
              <dd class="mt-1 text-xl font-bold text-gray-900">
                {format_number(stats[:multi_page_sessions] || 0)}
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-4">
              <dt class="text-xs font-medium text-gray-500">Pages/Session</dt>
              <dd class="mt-1 text-xl font-bold text-gray-900">
                {stats[:avg_pages_per_session] || 0}
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-4 border-t-4 border-green-400">
              <dt class="text-xs font-medium text-gray-500">Converted</dt>
              <dd class="mt-1 text-xl font-bold text-green-600">
                {format_number(stats[:converting_sessions] || 0)}
              </dd>
            </div>
            <div class="bg-white rounded-lg shadow p-4 border-t-4 border-red-400">
              <dt class="text-xs font-medium text-gray-500">Bounced</dt>
              <dd class="mt-1 text-xl font-bold text-red-600">
                {format_number(stats[:bounce_sessions] || 0)}
              </dd>
            </div>
          </div>

          <%!-- Converter Journeys --%>
          <.journey_section
            title="Converter Journeys"
            subtitle="Paths that touched a conversion page — the routes that produce results."
            color="green"
            journeys={@data.converters}
            site={@site}
            empty_msg="No conversions yet. Configure conversion pages in Site Settings → Visitor Journeys."
          />

          <%!-- Engaged Journeys --%>
          <.journey_section
            title="Engaged Journeys"
            subtitle="3+ pages visited but no conversion — interested visitors who didn't take action."
            color="blue"
            journeys={@data.engaged}
            site={@site}
            empty_msg="No engaged multi-page sessions in this period."
          />

          <%!-- Bounce Paths --%>
          <div class="bg-white rounded-lg shadow mb-8">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="font-semibold text-red-700">Bounce Paths</h3>
              <p class="text-xs text-gray-500 mt-0.5">
                Single-page sessions — visitors who left immediately. Grouped by page type and source.
              </p>
            </div>
            <%= if @data.bounced == [] do %>
              <div class="px-5 py-8 text-center text-gray-500 text-sm">
                No bounced sessions in this period.
              </div>
            <% else %>
              <table class="w-full">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Page
                    </th>
                    <th class="px-5 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                      Source
                    </th>
                    <th class="px-5 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                      Visitors
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-50">
                  <tr :for={b <- @data.bounced} class="hover:bg-red-50/30">
                    <td class="px-5 py-2 text-sm font-medium text-gray-900">{b.page}</td>
                    <td class="px-5 py-2 text-sm text-gray-600">{b.source}</td>
                    <td class="px-5 py-2 text-sm text-right tabular-nums font-semibold text-red-600">
                      {format_number(b.visitors)}
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  attr :color, :string, required: true
  attr :journeys, :list, required: true
  attr :site, :any, required: true
  attr :empty_msg, :string, required: true

  defp journey_section(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow mb-8">
      <div class="px-5 py-4 border-b border-gray-100">
        <h3 class={"font-semibold text-#{@color}-700"}>{@title}</h3>
        <p class="text-xs text-gray-500 mt-0.5">{@subtitle}</p>
      </div>
      <%= if @journeys == [] do %>
        <div class="px-5 py-8 text-center text-gray-500 text-sm">{@empty_msg}</div>
      <% else %>
        <div class="divide-y divide-gray-50">
          <div :for={{j, idx} <- Enum.with_index(@journeys)} class="px-5 py-4">
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2 mb-2">
                  <span class="text-xs text-gray-400">#{idx + 1}</span>
                  <div class="flex items-center flex-wrap gap-1">
                    <span
                      :for={{page, pi} <- Enum.with_index(j.pages)}
                      class="flex items-center gap-1"
                    >
                      <span class={[
                        "px-2 py-1 rounded text-xs font-medium",
                        "bg-#{@color}-50 text-#{@color}-800"
                      ]}>
                        {page}
                      </span>
                      <span :if={pi < length(j.pages) - 1} class="text-gray-300 text-xs">
                        &rarr;
                      </span>
                    </span>
                  </div>
                </div>
                <div class="flex flex-wrap items-center gap-3 text-xs text-gray-500">
                  <span>{format_number(j.visitors)} visitors</span>
                  <span :if={j.avg_duration > 0}>
                    {div(j.avg_duration, 60)}m {rem(j.avg_duration, 60)}s avg
                  </span>
                  <span :for={{source, count} <- j.sources} class="text-gray-400">
                    {source} ({count})
                  </span>
                </div>
              </div>
              <div class="text-right shrink-0">
                <div class="text-lg font-bold text-gray-900">{format_number(j.visitors)}</div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
