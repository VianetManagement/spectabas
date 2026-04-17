defmodule SpectabasWeb.Dashboard.PagesLive do
  use SpectabasWeb, :live_view

  @moduledoc "Top pages ranked by pageviews with RUM load time indicators."

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import SpectabasWeb.Dashboard.DateHelpers

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Pages - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:date_range, "7d")
        |> assign(:sort_by, "pageviews")
        |> assign(:sort_dir, "desc")
        |> assign(:expanded_row, nil)
        |> assign(:pages, [])
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    send(self(), :load_data)

    {:noreply,
     socket |> assign(:date_range, range) |> assign(:expanded_row, nil) |> assign(:loading, true)}
  end

  def handle_event("sort", %{"field" => field}, socket) do
    dir =
      if socket.assigns.sort_by == field do
        if socket.assigns.sort_dir == "asc", do: "desc", else: "asc"
      else
        "desc"
      end

    send(self(), :load_data)

    {:noreply,
     socket |> assign(:sort_by, field) |> assign(:sort_dir, dir) |> assign(:loading, true)}
  end

  def handle_event("toggle_row", %{"path" => path}, socket) do
    if socket.assigns.expanded_row == path do
      {:noreply, assign(socket, :expanded_row, nil)}
    else
      site = socket.assigns.site
      user = socket.assigns.user
      period = range_to_period(socket.assigns.date_range)

      case Analytics.row_timeseries(site, user, period, "url_path", path) do
        {:ok, rows} ->
          labels = Enum.map(rows, & &1["bucket"])
          values = Enum.map(rows, &to_num(&1["pageviews"]))

          {:noreply,
           socket
           |> assign(:expanded_row, path)
           |> push_event("sparkline-data", %{
             id: "sparkline-#{Base.encode16(path)}",
             labels: labels,
             values: values
           })}

        _ ->
          {:noreply, assign(socket, :expanded_row, path)}
      end
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, socket |> load_pages() |> assign(:loading, false)}
  end

  defp load_pages(socket) do
    %{site: site, user: user, date_range: range} = socket.assigns
    period = range_to_period(range)

    pages = safe_query(fn -> Analytics.top_pages(site, user, period) end)

    # Fetch per-page RUM vitals summary and merge into page rows
    # Use normalized paths for matching (lowercase, no trailing slash)
    vitals_rows = safe_query(fn -> Analytics.rum_vitals_summary(site, user, period) end)

    vitals_map =
      Map.new(vitals_rows, fn r ->
        path = (r["url_path"] || "/") |> String.downcase() |> String.trim_trailing("/")
        path = if path == "", do: "/", else: path
        {path, r}
      end)

    # Fetch per-page device split
    device_rows = safe_query(fn -> Analytics.page_device_split(site, user, period) end)
    device_map = build_device_map(device_rows)

    pages =
      Enum.map(pages, fn page ->
        path = (page["url_path"] || "/") |> String.downcase() |> String.trim_trailing("/")
        path = if path == "", do: "/", else: path
        rum = Map.get(vitals_map, path, %{})
        devices = Map.get(device_map, page["url_path"], %{})

        Map.merge(page, %{
          "page_load" => rum["page_load"],
          "devices" => devices
        })
      end)

    assign(socket, :pages, pages)
  end

  defp build_device_map(rows) do
    rows
    |> Enum.group_by(& &1["url_path"])
    |> Map.new(fn {path, group} ->
      total = Enum.reduce(group, 0, fn r, acc -> acc + to_num(r["pv"]) end)

      pcts =
        if total > 0 do
          Map.new(group, fn r ->
            {r["device_type"], round(to_num(r["pv"]) / total * 100)}
          end)
        else
          %{}
        end

      {path, pcts}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Pages"
      page_description="Top pages ranked by pageviews and unique visitors."
      active="pages"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-2xl font-bold text-gray-900 mt-2">Top Pages</h1>
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
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Page
                  </th>
                  <.sort_header
                    field="pageviews"
                    label="Pageviews"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="unique_visitors"
                    label="Visitors"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                  />
                  <.sort_header
                    field="avg_duration"
                    label="Avg Duration"
                    sort_by={@sort_by}
                    sort_dir={@sort_dir}
                  />
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Load Time
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                    Devices
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :if={@pages == []}>
                  <td colspan="6" class="px-6 py-8 text-center text-gray-500">
                    No data for this period.
                  </td>
                </tr>
                <%= for page <- @pages do %>
                  <tr
                    phx-click="toggle_row"
                    phx-value-path={Map.get(page, "url_path", "/")}
                    class={[
                      "hover:bg-gray-50 cursor-pointer",
                      if(@expanded_row == Map.get(page, "url_path", "/"),
                        do: "bg-indigo-50",
                        else: ""
                      )
                    ]}
                  >
                    <td class="px-6 py-4 text-sm truncate max-w-md">
                      <.link
                        navigate={
                          ~p"/dashboard/sites/#{@site.id}/transitions?page=#{Map.get(page, "url_path", "/")}"
                        }
                        class="text-indigo-600 hover:text-indigo-800 font-mono"
                        title="View page transitions"
                      >
                        {Map.get(page, "url_path", "/")}
                      </.link>
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(Map.get(page, "pageviews", 0)))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                      {format_number(to_num(Map.get(page, "unique_visitors", 0)))}
                    </td>
                    <td class="px-6 py-4 text-sm text-gray-900 text-right">
                      {format_duration(to_num(Map.get(page, "avg_duration", 0)))}
                    </td>
                    <td class="px-6 py-4 text-sm text-right tabular-nums">
                      <.speed_pill ms={to_num(page["page_load"])} />
                    </td>
                    <td class="px-6 py-4 text-sm">
                      <.device_bar devices={Map.get(page, "devices", %{})} />
                    </td>
                  </tr>
                  <tr :if={@expanded_row == Map.get(page, "url_path", "/")}>
                    <td colspan="6" class="px-6 py-4 bg-gray-50">
                      <div class="flex items-center gap-4">
                        <span class="text-sm text-gray-500 font-mono">
                          {Map.get(page, "url_path", "/")}
                        </span>
                        <span class="text-xs text-gray-400">Pageview trend</span>
                      </div>
                      <div
                        id={"sparkline-#{Base.encode16(Map.get(page, "url_path", "/"))}"}
                        phx-hook="Sparkline"
                        class="h-20 mt-2"
                      >
                        <canvas></canvas>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp sort_header(assigns) do
    ~H"""
    <th
      class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:text-gray-700"
      phx-click="sort"
      phx-value-field={@field}
    >
      {@label}
      <span :if={@sort_by == @field}>
        {if @sort_dir == "asc", do: raw("&uarr;"), else: raw("&darr;")}
      </span>
    </th>
    """
  end

  defp device_bar(assigns) do
    devices = assigns.devices
    desktop = Map.get(devices, "Desktop", 0)
    mobile = Map.get(devices, "Mobile", 0)
    tablet = Map.get(devices, "Tablet", 0)

    assigns =
      Map.merge(assigns, %{
        desktop: desktop,
        mobile: mobile,
        tablet: tablet,
        has_data: desktop + mobile + tablet > 0
      })

    ~H"""
    <div :if={@has_data} class="flex items-center gap-1.5 text-xs tabular-nums whitespace-nowrap">
      <span :if={@desktop > 0} class="text-blue-700" title="Desktop">D {@desktop}%</span>
      <span :if={@mobile > 0} class="text-green-700" title="Mobile">M {@mobile}%</span>
      <span :if={@tablet > 0} class="text-amber-700" title="Tablet">T {@tablet}%</span>
    </div>
    <span :if={!@has_data} class="text-gray-400 text-xs">—</span>
    """
  end

  defp speed_pill(assigns) do
    ms = assigns.ms

    {label, classes} =
      cond do
        ms == 0 -> {"—", "text-gray-500"}
        ms <= 1000 -> {format_ms(ms), "text-green-700 bg-green-50 border border-green-200"}
        ms <= 3000 -> {format_ms(ms), "text-amber-700 bg-amber-50 border border-amber-200"}
        true -> {format_ms(ms), "text-red-700 bg-red-50 border border-red-200"}
      end

    assigns = Map.merge(assigns, %{label: label, classes: classes})

    ~H"""
    <span :if={@ms > 0} class={"inline-block px-2 py-0.5 rounded text-xs font-medium #{@classes}"}>
      {@label}
    </span>
    <span :if={@ms == 0} class="text-gray-500 text-xs">—</span>
    """
  end
end
