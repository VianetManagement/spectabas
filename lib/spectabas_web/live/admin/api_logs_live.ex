defmodule SpectabasWeb.Admin.ApiLogsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.Repo
  alias Spectabas.Accounts.ApiAccessLog
  import Ecto.Query
  import Spectabas.TypeHelpers

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "API Access Logs")
     |> assign(:filter_method, nil)
     |> assign(:filter_path, nil)
     |> assign(:page, 1)
     |> load_logs()
     |> load_stats()}
  end

  @impl true
  def handle_event("filter", %{"method" => method, "path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:filter_method, if(method == "", do: nil, else: method))
     |> assign(:filter_path, if(path == "", do: nil, else: path))
     |> assign(:page, 1)
     |> load_logs()}
  end

  def handle_event("next_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:page, socket.assigns.page + 1)
     |> load_logs()}
  end

  def handle_event("prev_page", _params, socket) do
    {:noreply,
     socket
     |> assign(:page, max(1, socket.assigns.page - 1))
     |> load_logs()}
  end

  defp load_logs(socket) do
    %{page: page, filter_method: method, filter_path: path} = socket.assigns
    offset = (page - 1) * @per_page

    query =
      from(l in ApiAccessLog,
        order_by: [desc: l.inserted_at],
        limit: ^@per_page,
        offset: ^offset
      )

    query = if method, do: where(query, [l], l.method == ^method), else: query
    query = if path, do: where(query, [l], like(l.path, ^"%#{path}%")), else: query

    logs = Repo.all(query)
    total = Repo.aggregate(ApiAccessLog, :count, :id)

    socket
    |> assign(:logs, logs)
    |> assign(:total, total)
  end

  defp load_stats(socket) do
    now = DateTime.utc_now()
    hour_ago = DateTime.add(now, -3600, :second)
    day_ago = DateTime.add(now, -86400, :second)

    calls_last_hour =
      Repo.aggregate(
        from(l in ApiAccessLog, where: l.inserted_at >= ^hour_ago),
        :count,
        :id
      )

    calls_last_day =
      Repo.aggregate(
        from(l in ApiAccessLog, where: l.inserted_at >= ^day_ago),
        :count,
        :id
      )

    by_endpoint =
      Repo.all(
        from(l in ApiAccessLog,
          where: l.inserted_at >= ^day_ago,
          group_by: [l.method, l.path],
          select: %{
            method: l.method,
            path: l.path,
            count: count(l.id),
            avg_ms: avg(l.duration_ms)
          },
          order_by: [desc: count(l.id)],
          limit: 15
        )
      )

    by_key =
      Repo.all(
        from(l in ApiAccessLog,
          where: l.inserted_at >= ^day_ago and not is_nil(l.key_prefix),
          group_by: l.key_prefix,
          select: %{key_prefix: l.key_prefix, count: count(l.id), avg_ms: avg(l.duration_ms)},
          order_by: [desc: count(l.id)],
          limit: 10
        )
      )

    by_status =
      Repo.all(
        from(l in ApiAccessLog,
          where: l.inserted_at >= ^day_ago,
          group_by: l.status_code,
          select: %{status: l.status_code, count: count(l.id)},
          order_by: [desc: count(l.id)]
        )
      )

    socket
    |> assign(:calls_last_hour, calls_last_hour)
    |> assign(:calls_last_day, calls_last_day)
    |> assign(:by_endpoint, by_endpoint)
    |> assign(:by_key, by_key)
    |> assign(:by_status, by_status)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-6">
        <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
          &larr; Admin Dashboard
        </.link>
      </div>

      <h1 class="text-2xl font-bold text-gray-900 mb-8">API Access Logs</h1>

      <%!-- Stats cards --%>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-xs font-medium text-gray-500 uppercase">Total Logged</dt>
          <dd class="mt-1 text-2xl font-bold text-gray-900">{format_number(@total)}</dd>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-xs font-medium text-gray-500 uppercase">Last Hour</dt>
          <dd class="mt-1 text-2xl font-bold text-indigo-600">{format_number(@calls_last_hour)}</dd>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-xs font-medium text-gray-500 uppercase">Last 24h</dt>
          <dd class="mt-1 text-2xl font-bold text-indigo-600">{format_number(@calls_last_day)}</dd>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-xs font-medium text-gray-500 uppercase">Status Codes (24h)</dt>
          <div class="mt-1 space-y-0.5">
            <div :for={s <- @by_status} class="flex justify-between text-sm">
              <span class={[
                "font-mono",
                if(s.status >= 400, do: "text-red-600", else: "text-green-600")
              ]}>
                {s.status}
              </span>
              <span class="text-gray-900 tabular-nums">{format_number(s.count)}</span>
            </div>
          </div>
        </div>
      </div>

      <%!-- Top endpoints + top keys --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-8">
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Top Endpoints (24h)</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Endpoint
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Calls
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Avg ms
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={e <- @by_endpoint} class="hover:bg-gray-50">
                <td class="px-4 py-2 text-sm">
                  <span class={[
                    "inline-block w-12 text-center text-xs font-medium rounded px-1 py-0.5 mr-2",
                    if(e.method == "POST",
                      do: "bg-green-100 text-green-700",
                      else: "bg-blue-100 text-blue-700"
                    )
                  ]}>
                    {e.method}
                  </span>
                  <span class="font-mono text-xs text-gray-700">{e.path}</span>
                </td>
                <td class="px-4 py-2 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(e.count)}
                </td>
                <td class="px-4 py-2 text-sm text-gray-500 text-right tabular-nums">
                  {if e.avg_ms, do: "#{round(Decimal.to_float(e.avg_ms))}ms", else: "-"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Top API Keys (24h)</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Key Prefix
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Calls
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Avg ms
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={k <- @by_key} class="hover:bg-gray-50">
                <td class="px-4 py-2 text-sm font-mono text-gray-700">{k.key_prefix}</td>
                <td class="px-4 py-2 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(k.count)}
                </td>
                <td class="px-4 py-2 text-sm text-gray-500 text-right tabular-nums">
                  {if k.avg_ms, do: "#{round(Decimal.to_float(k.avg_ms))}ms", else: "-"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Filter + log table --%>
      <div class="bg-white rounded-lg shadow">
        <div class="px-6 py-4 border-b border-gray-100">
          <form phx-submit="filter" class="flex gap-3 items-end">
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Method</label>
              <select name="method" class="text-sm border-gray-300 rounded-md px-2 py-1.5">
                <option value="">All</option>
                <option value="GET" selected={@filter_method == "GET"}>GET</option>
                <option value="POST" selected={@filter_method == "POST"}>POST</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-500 mb-1">Path contains</label>
              <input
                type="text"
                name="path"
                value={@filter_path || ""}
                placeholder="e.g. identify"
                class="text-sm border-gray-300 rounded-md px-2 py-1.5"
              />
            </div>
            <button
              type="submit"
              class="px-3 py-1.5 bg-indigo-600 text-white text-sm rounded-md hover:bg-indigo-700"
            >
              Filter
            </button>
          </form>
        </div>

        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Time</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                Method
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Path</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Key</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                Status
              </th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                Duration
              </th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">IP</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :if={@logs == []}>
              <td colspan="7" class="px-4 py-8 text-center text-gray-500">No API calls logged.</td>
            </tr>
            <tr :for={log <- @logs} class="hover:bg-gray-50">
              <td class="px-4 py-2 text-xs text-gray-500">
                {Calendar.strftime(log.inserted_at, "%m-%d %H:%M:%S")}
              </td>
              <td class="px-4 py-2 text-xs">
                <span class={[
                  "inline-block text-center font-medium rounded px-1.5 py-0.5",
                  if(log.method == "POST",
                    do: "bg-green-100 text-green-700",
                    else: "bg-blue-100 text-blue-700"
                  )
                ]}>
                  {log.method}
                </span>
              </td>
              <td class="px-4 py-2 text-xs font-mono text-gray-700 truncate max-w-[250px]">
                {log.path}
              </td>
              <td class="px-4 py-2 text-xs font-mono text-gray-500">{log.key_prefix}</td>
              <td class="px-4 py-2 text-xs text-right tabular-nums">
                <span class={
                  if log.status_code >= 400, do: "text-red-600 font-bold", else: "text-gray-700"
                }>
                  {log.status_code}
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-right tabular-nums text-gray-500">
                {if log.duration_ms, do: "#{log.duration_ms}ms", else: "-"}
              </td>
              <td class="px-4 py-2 text-xs text-gray-500 font-mono">{log.ip_address}</td>
            </tr>
          </tbody>
        </table>

        <div class="px-6 py-3 border-t border-gray-100 flex justify-between items-center">
          <span class="text-xs text-gray-500">
            Page {@page} &middot; {format_number(@total)} total
          </span>
          <div class="flex gap-2">
            <button
              :if={@page > 1}
              phx-click="prev_page"
              class="px-3 py-1 text-sm bg-gray-100 rounded hover:bg-gray-200"
            >
              &larr; Prev
            </button>
            <button
              :if={length(@logs) == 50}
              phx-click="next_page"
              class="px-3 py-1 text-sm bg-gray-100 rounded hover:bg-gray-200"
            >
              Next &rarr;
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
