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

    if !Accounts.can_access_site?(user, site) do
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
        |> assign(:show_config, false)

      if connected?(socket), do: send(self(), :load_data)

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)
    {:noreply, socket |> assign(:date_range, range) |> assign(:loading, true)}
  end

  def handle_event("toggle_config", _params, socket) do
    {:noreply, assign(socket, :show_config, !socket.assigns.show_config)}
  end

  def handle_event(
        "save_config",
        %{"prefixes" => prefixes_text, "conversions" => conv_text},
        socket
      ) do
    if !Accounts.can_manage_settings?(socket.assigns.current_scope.user) do
      {:noreply, put_flash(socket, :error, "Insufficient permissions.")}
    else
      prefixes = parse_lines(prefixes_text)
      conversions = parse_lines(conv_text)

      case Sites.update_site(socket.assigns.site, %{
             scraper_content_prefixes: prefixes,
             journey_conversion_pages: conversions
           }) do
        {:ok, site} ->
          send(self(), :load_data)

          {:noreply,
           socket
           |> assign(:site, site)
           |> assign(:loading, true)
           |> assign(:show_config, false)
           |> put_flash(:info, "Configuration saved. Reloading journeys...")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save configuration.")}
      end
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
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

        <%!-- Inline config panel --%>
        <div class="mb-6">
          <button
            phx-click="toggle_config"
            class="text-sm text-indigo-600 hover:text-indigo-800 flex items-center gap-1"
          >
            <span>
              {if @show_config, do: "Hide", else: "Configure"} page grouping &amp; conversion pages
            </span>
            <span class="text-xs">{if @show_config, do: "▲", else: "▼"}</span>
          </button>

          <%= if @show_config do %>
            <form phx-submit="save_config" class="bg-white rounded-lg shadow p-5 mt-3 space-y-4">
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">
                    Content path prefixes
                  </label>
                  <p class="text-xs text-gray-500 mb-2">
                    URLs matching these prefixes get grouped by type
                    (e.g. <span class="font-mono">/listings</span> → "Listings").
                    One per line.
                  </p>
                  <textarea
                    name="prefixes"
                    rows="4"
                    class="block w-full rounded-lg border-gray-300 shadow-sm text-xs font-mono"
                    placeholder="/listings&#10;/premier&#10;/breeds"
                  ><%= Enum.join(@site.scraper_content_prefixes || [], "\n") %></textarea>
                </div>
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">
                    Conversion pages
                  </label>
                  <p class="text-xs text-gray-500 mb-2">
                    Pages that count as a conversion. Matched as prefixes
                    (e.g. <span class="font-mono">/contact</span>
                    matches <span class="font-mono">/contact/thank-you</span>). One per line.
                  </p>
                  <textarea
                    name="conversions"
                    rows="4"
                    class="block w-full rounded-lg border-gray-300 shadow-sm text-xs font-mono"
                    placeholder="/contact&#10;/checkout&#10;/signup"
                  ><%= Enum.join(@site.journey_conversion_pages || [], "\n") %></textarea>
                </div>
              </div>
              <div class="flex justify-end">
                <button
                  type="submit"
                  class="px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
                >
                  Save &amp; Reload
                </button>
              </div>
            </form>
          <% end %>

          <%= if !@show_config and (Enum.empty?(@site.scraper_content_prefixes || []) or Enum.empty?(@site.journey_conversion_pages || [])) do %>
            <p class="text-xs text-amber-600 mt-1">
              <%= if Enum.empty?(@site.scraper_content_prefixes || []) do %>
                Content prefixes not set — URLs won't be grouped.
              <% end %>
              <%= if Enum.empty?(@site.journey_conversion_pages || []) do %>
                Conversion pages not set — converter journeys won't appear.
              <% end %>
            </p>
          <% end %>
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
              <div class="overflow-x-auto">
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
              </div>
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
                        "px-2 py-1 rounded text-xs font-medium max-w-[120px] truncate",
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

  defp parse_lines(text) when is_binary(text) do
    text |> String.split(~r/[,\n]/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp parse_lines(_), do: []
end
