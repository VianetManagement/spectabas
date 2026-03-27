defmodule SpectabasWeb.Admin.AuditLive do
  use SpectabasWeb, :live_view

  alias Spectabas.Repo
  alias Spectabas.Accounts.AuditLog
  import Ecto.Query

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audit Log")
     |> assign(:page, 1)
     |> assign(:event_filter, "")
     |> load_logs()}
  end

  @impl true
  def handle_event("filter", %{"event" => event}, socket) do
    {:noreply,
     socket
     |> assign(:event_filter, event)
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
    page = max(1, socket.assigns.page - 1)

    {:noreply,
     socket
     |> assign(:page, page)
     |> load_logs()}
  end

  defp load_logs(socket) do
    %{page: page, event_filter: event_filter} = socket.assigns

    query =
      from(a in AuditLog,
        order_by: [desc: a.occurred_at],
        limit: ^@page_size,
        offset: ^((page - 1) * @page_size)
      )

    query =
      if event_filter != "" do
        from(a in query, where: ilike(a.event, ^"%#{event_filter}%"))
      else
        query
      end

    logs = Repo.all(query)
    total = Repo.aggregate(base_query(event_filter), :count, :id)

    socket
    |> assign(:logs, logs)
    |> assign(:total, total)
    |> assign(:total_pages, max(1, ceil(total / @page_size)))
  end

  defp base_query(""), do: from(a in AuditLog)

  defp base_query(event_filter) do
    from(a in AuditLog, where: ilike(a.event, ^"%#{event_filter}%"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
          &larr; Admin Dashboard
        </.link>
        <h1 class="text-2xl font-bold text-gray-900 mt-2">Audit Log</h1>
        <p class="text-sm text-gray-500 mt-1">{@total} total entries</p>
      </div>

      <div class="mb-6">
        <form phx-change="filter" class="flex gap-4 items-end">
          <div class="flex-1 max-w-sm">
            <label class="block text-sm font-medium text-gray-700">Filter by event</label>
            <input
              type="text"
              name="event"
              value={@event_filter}
              placeholder="e.g. totp, login, role"
              class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
            />
          </div>
        </form>
      </div>

      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Time
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Event
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                User ID
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Metadata
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :if={@logs == []}>
              <td colspan="4" class="px-6 py-8 text-center text-gray-500">No audit entries found.</td>
            </tr>
            <tr :for={log <- @logs} class="hover:bg-gray-50">
              <td class="px-6 py-4 text-sm text-gray-500 whitespace-nowrap">
                {if log.occurred_at,
                  do: Calendar.strftime(log.occurred_at, "%Y-%m-%d %H:%M:%S"),
                  else: "-"}
              </td>
              <td class="px-6 py-4">
                <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-indigo-100 text-indigo-800">
                  {log.event}
                </span>
              </td>
              <td class="px-6 py-4 text-sm text-gray-500 font-mono">
                {log.user_id || "-"}
              </td>
              <td class="px-6 py-4 text-sm text-gray-500 max-w-md truncate font-mono">
                {if log.metadata && log.metadata != %{}, do: Jason.encode!(log.metadata), else: "-"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="flex items-center justify-between mt-4">
        <p class="text-sm text-gray-500">
          Page {@page} of {@total_pages}
        </p>
        <div class="flex gap-2">
          <button
            :if={@page > 1}
            phx-click="prev_page"
            class="px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
          >
            Previous
          </button>
          <button
            :if={@page < @total_pages}
            phx-click="next_page"
            class="px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
          >
            Next
          </button>
        </div>
      </div>
    </div>
    """
  end
end
