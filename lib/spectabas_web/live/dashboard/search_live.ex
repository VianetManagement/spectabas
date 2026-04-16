defmodule SpectabasWeb.Dashboard.SearchLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @default_search_params ~w(q query search s keyword)

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      tracked_params =
        case site.search_query_params do
          list when is_list(list) and list != [] -> list
          _ -> @default_search_params
        end

      socket =
        socket
        |> assign(:page_title, "Site Search - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "30d")
        |> assign(:param_filter, nil)
        |> assign(:loading, true)
        |> assign(:searches, [])
        |> assign(:stats, nil)
        |> assign(:trend, [])
        |> assign(:search_pages, [])
        |> assign(:params_used, [])
        |> assign(:tracked_params, tracked_params)
        |> assign(:using_defaults, site.search_query_params in [nil, []])

      if connected?(socket) do
        send(self(), :load_critical)
        send(self(), :load_deferred)
      end

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    socket = socket |> assign(:date_range, range) |> assign(:loading, true)
    send(self(), :load_critical)
    send(self(), :load_deferred)
    {:noreply, socket}
  end

  def handle_event("filter_param", %{"param" => "all"}, socket) do
    socket = socket |> assign(:param_filter, nil) |> assign(:loading, true)
    send(self(), :load_critical)
    {:noreply, socket}
  end

  def handle_event("filter_param", %{"param" => param}, socket) do
    socket = socket |> assign(:param_filter, param) |> assign(:loading, true)
    send(self(), :load_critical)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_critical, socket) do
    # Critical path: searches table + params_used (for filter pills) — render immediately
    %{site: site, user: user, date_range: range, param_filter: param_filter} = socket.assigns
    period = range_to_period(range)

    tasks = [
      Task.async(fn ->
        {:searches, Analytics.site_searches(site, user, period, param: param_filter)}
      end),
      Task.async(fn -> {:params_used, Analytics.site_search_params_used(site, user, period)} end)
    ]

    socket =
      tasks
      |> Task.await_many(30_000)
      |> Enum.reduce(socket, fn
        {:searches, {:ok, rows}}, sock -> assign(sock, :searches, rows)
        {:params_used, {:ok, rows}}, sock -> assign(sock, :params_used, rows)
        _, sock -> sock
      end)

    {:noreply, assign(socket, :loading, false)}
  end

  def handle_info(:load_deferred, socket) do
    # Deferred: stats cards, trend chart, search pages — fire independently
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)
    pid = self()

    for {key, fun} <- [
          stats: fn -> Analytics.site_search_stats(site, user, period) end,
          trend: fn -> Analytics.site_search_trend(site, user, period) end,
          search_pages: fn -> Analytics.site_search_pages(site, user, period) end
        ] do
      Task.start(fn ->
        case fun.() do
          {:ok, rows} -> send(pid, {:deferred, key, rows})
          _ -> :ok
        end
      end)
    end

    {:noreply, socket}
  end

  def handle_info({:deferred, :stats, [row | _]}, socket) do
    {:noreply, assign(socket, :stats, row)}
  end

  def handle_info({:deferred, key, rows}, socket) when key in [:trend, :search_pages] do
    {:noreply, assign(socket, key, rows)}
  end

  def handle_info({:deferred, _, _}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Site Search"
      page_description="Internal search queries from URL parameters."
      active="search"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between mb-6 gap-4">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Site Search</h1>
            <p class="text-sm text-gray-500 mt-1">
              What visitors are searching for on your site
            </p>
          </div>
          <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={r <- [{"7d", "7 days"}, {"30d", "30 days"}, {"90d", "90 days"}]}
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

        <%!-- Tracked Parameters Banner --%>
        <div class="bg-indigo-50 border border-indigo-200 rounded-lg px-4 py-3 mb-6">
          <div class="flex items-start justify-between gap-4">
            <div>
              <div class="text-xs font-semibold text-indigo-800 uppercase mb-1">
                Tracking URL Parameters
              </div>
              <div class="flex flex-wrap gap-1.5">
                <span
                  :for={param <- @tracked_params}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-mono font-medium bg-indigo-100 text-indigo-700"
                >
                  ?{param}=
                </span>
              </div>
              <p :if={@using_defaults} class="text-xs text-indigo-600 mt-1.5">
                Using default parameters.
                <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/settings"}
                  class="underline hover:text-indigo-800"
                >
                  Customize in Settings &rarr;
                </.link>
              </p>
              <p :if={!@using_defaults} class="text-xs text-indigo-600 mt-1.5">
                Custom parameters configured.
                <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/settings"}
                  class="underline hover:text-indigo-800"
                >
                  Edit in Settings &rarr;
                </.link>
              </p>
            </div>
          </div>
        </div>

        <%!-- Parameter Filter Pills --%>
        <div :if={@params_used != [] && !@loading} class="flex flex-wrap items-center gap-2 mb-6">
          <span class="text-xs font-medium text-gray-500 uppercase mr-1">Filter by param:</span>
          <button
            phx-click="filter_param"
            phx-value-param="all"
            class={[
              "px-3 py-1 text-xs font-medium rounded-full border",
              if(is_nil(@param_filter),
                do: "bg-indigo-600 text-white border-indigo-600",
                else: "bg-white text-gray-700 border-gray-300 hover:bg-gray-50"
              )
            ]}
          >
            All
          </button>
          <button
            :for={pu <- @params_used}
            phx-click="filter_param"
            phx-value-param={pu["param"]}
            class={[
              "px-3 py-1 text-xs font-medium rounded-full border font-mono",
              if(@param_filter == pu["param"],
                do: "bg-indigo-600 text-white border-indigo-600",
                else: "bg-white text-gray-700 border-gray-300 hover:bg-gray-50"
              )
            ]}
          >
            ?{pu["param"]}=
            <span class={[
              "ml-1 text-xs",
              if(@param_filter == pu["param"], do: "text-indigo-200", else: "text-gray-400")
            ]}>
              {format_number(to_num(pu["cnt"]))}
            </span>
          </button>
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
          <%!-- Stats Cards --%>
          <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
            <div class="bg-white rounded-lg shadow px-5 py-4">
              <div class="text-xs font-medium text-gray-500 uppercase">Total Searches</div>
              <div class="text-2xl font-bold text-gray-900 mt-1">
                {format_number(to_num((@stats || %{})["total_searches"]))}
              </div>
            </div>
            <div class="bg-white rounded-lg shadow px-5 py-4">
              <div class="text-xs font-medium text-gray-500 uppercase">Unique Searchers</div>
              <div class="text-2xl font-bold text-gray-900 mt-1">
                {format_number(to_num((@stats || %{})["unique_searchers"]))}
              </div>
            </div>
            <div class="bg-white rounded-lg shadow px-5 py-4">
              <div class="text-xs font-medium text-gray-500 uppercase">Unique Terms</div>
              <div class="text-2xl font-bold text-gray-900 mt-1">
                {format_number(to_num((@stats || %{})["unique_terms"]))}
              </div>
            </div>
            <div class="bg-white rounded-lg shadow px-5 py-4">
              <div class="text-xs font-medium text-gray-500 uppercase">Searches / Searcher</div>
              <div class="text-2xl font-bold text-gray-900 mt-1">
                {searches_per_searcher(@stats)}
              </div>
            </div>
          </div>

          <%!-- Search Trend --%>
          <%= if @trend != [] do %>
            <div class="bg-white rounded-lg shadow p-5 mb-6">
              <h2 class="text-sm font-semibold text-gray-900 mb-3">Search Volume</h2>
              <div class="flex items-end gap-px h-24">
                <% max_val = @trend |> Enum.map(&to_num(&1["searches"])) |> Enum.max(fn -> 1 end) %>
                <div
                  :for={d <- @trend}
                  class="flex-1 bg-indigo-500 rounded-t hover:bg-indigo-600 transition-colors relative group"
                  style={"height: #{bar_height(to_num(d["searches"]), max_val)}%"}
                >
                  <div class="absolute bottom-full mb-1 left-1/2 -translate-x-1/2 hidden group-hover:block bg-gray-900 text-white text-xs rounded px-2 py-1 whitespace-nowrap z-10">
                    {d["day"]} &mdash; {format_number(to_num(d["searches"]))} searches
                  </div>
                </div>
              </div>
              <div class="flex justify-between mt-1 text-xs text-gray-400">
                <span>{List.first(@trend)["day"]}</span>
                <span>{List.last(@trend)["day"]}</span>
              </div>
            </div>
          <% end %>

          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-6">
            <%!-- Search Terms Table (2/3 width) --%>
            <div class="lg:col-span-2 bg-white rounded-lg shadow overflow-x-auto">
              <div class="px-6 py-4 border-b border-gray-200">
                <h2 class="text-base font-semibold text-gray-900">Top Search Terms</h2>
                <p class="text-xs text-gray-500 mt-0.5">What visitors type into your search</p>
              </div>
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      Search Term
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Searches
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Searchers
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase hidden sm:table-cell">
                      Avg / Person
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :if={@searches == []}>
                    <td colspan="4" class="px-6 py-8 text-center text-gray-500 text-sm">
                      No search queries found in this period. Make sure your site's search results page
                      uses one of the tracked URL parameters shown above.
                    </td>
                  </tr>
                  <tr :for={s <- @searches} class="hover:bg-gray-50">
                    <td class="px-6 py-3 text-sm font-medium text-gray-900">
                      <span class="inline-flex items-center gap-2">
                        {s["search_term"]}
                        <span
                          :if={s["search_param"] && s["search_param"] != ""}
                          class="inline-flex items-center px-1.5 py-0 rounded text-[10px] font-mono font-medium bg-gray-100 text-gray-500 border border-gray-200"
                        >
                          {s["search_param"]}
                        </span>
                      </span>
                    </td>
                    <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(s["searches"]))}
                    </td>
                    <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(s["unique_searchers"]))}
                    </td>
                    <td class="px-6 py-3 text-sm text-gray-500 text-right tabular-nums hidden sm:table-cell">
                      {avg_per_person(s)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Search Pages (1/3 width) --%>
            <div class="bg-white rounded-lg shadow overflow-x-auto">
              <div class="px-6 py-4 border-b border-gray-200">
                <h2 class="text-base font-semibold text-gray-900">Search Pages</h2>
                <p class="text-xs text-gray-500 mt-0.5">Pages where search happens</p>
              </div>
              <table class="min-w-full divide-y divide-gray-200">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                      Page
                    </th>
                    <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                      Searches
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-200">
                  <tr :if={@search_pages == []}>
                    <td colspan="2" class="px-6 py-6 text-center text-gray-500 text-sm">
                      No data yet.
                    </td>
                  </tr>
                  <tr :for={p <- @search_pages} class="hover:bg-gray-50">
                    <td
                      class="px-6 py-3 text-sm text-indigo-700 font-mono truncate max-w-[200px]"
                      title={p["url_path"]}
                    >
                      {p["url_path"]}
                    </td>
                    <td class="px-6 py-3 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(p["searches"]))}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp searches_per_searcher(nil), do: "0"

  defp searches_per_searcher(stats) do
    total = to_num(stats["total_searches"])
    searchers = to_num(stats["unique_searchers"])
    if searchers > 0, do: Float.round(total / searchers, 1) |> to_string(), else: "0"
  end

  defp avg_per_person(row) do
    searches = to_num(row["searches"])
    searchers = to_num(row["unique_searchers"])
    if searchers > 0, do: Float.round(searches / searchers, 1) |> to_string(), else: "1"
  end

  defp bar_height(val, max) when max > 0, do: round(val / max * 100) |> max(2)
  defp bar_height(_, _), do: 2
end
