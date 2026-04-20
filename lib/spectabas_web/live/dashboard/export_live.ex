defmodule SpectabasWeb.Dashboard.ExportLive do
  use SpectabasWeb, :live_view

  @moduledoc "Data export page — CSV downloads with date range selection."

  alias Spectabas.{Accounts, Sites, Reports}
  import SpectabasWeb.Dashboard.SidebarComponent

  @poll_interval_ms 5_000

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
      today =
        case DateTime.now(site.timezone || "UTC") do
          {:ok, local_now} -> DateTime.to_date(local_now)
          _ -> Date.utc_today()
        end

      from = Date.add(today, -30)

      {:ok,
       socket
       |> assign(:page_title, "Export - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_from, Date.to_iso8601(from))
       |> assign(:date_to, Date.to_iso8601(today))
       |> assign(:format, "csv")
       |> assign(:export, nil)
       |> assign(:polling, false)}
    end
  end

  @impl true
  def handle_event("update_form", params, socket) do
    socket =
      socket
      |> assign(:date_from, Map.get(params, "date_from", socket.assigns.date_from))
      |> assign(:date_to, Map.get(params, "date_to", socket.assigns.date_to))
      |> assign(:format, Map.get(params, "format", socket.assigns.format))

    {:noreply, socket}
  end

  def handle_event("start_export", _params, socket) do
    %{site: site, user: user, date_from: from, date_to: to, format: fmt} = socket.assigns

    case Reports.create_export(site, user, %{
           date_from: from,
           date_to: to,
           format: fmt
         }) do
      {:ok, export} ->
        if connected?(socket), do: schedule_poll()

        {:noreply,
         socket
         |> assign(:export, export)
         |> assign(:polling, true)
         |> put_flash(:info, "Export started.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to start export.")}
    end
  end

  @impl true
  def handle_info(:poll_export, socket) do
    case socket.assigns.export do
      nil ->
        {:noreply, assign(socket, :polling, false)}

      export ->
        updated = Reports.get_export!(export.id)

        if updated.status in ["completed", "failed"] do
          {:noreply,
           socket
           |> assign(:export, updated)
           |> assign(:polling, false)}
        else
          schedule_poll()
          {:noreply, assign(socket, :export, updated)}
        end
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_poll, do: Process.send_after(self(), :poll_export, @poll_interval_ms)

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Exports"
      page_description="Export your analytics data."
      active="exports"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-gray-900">Data Export</h1>
        </div>

        <div class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Export Configuration</h2>
          <form phx-change="update_form" phx-submit="start_export" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">Date From</label>
                <input
                  type="date"
                  name="date_from"
                  value={@date_from}
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Date To</label>
                <input
                  type="date"
                  name="date_to"
                  value={@date_to}
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Format</label>
                <select
                  name="format"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <option value="csv" selected={@format == "csv"}>CSV</option>
                  <option value="json" selected={@format == "json"}>JSON</option>
                </select>
              </div>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                disabled={@polling}
                class={[
                  "inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white",
                  if(@polling,
                    do: "bg-gray-400 cursor-not-allowed",
                    else: "bg-indigo-600 hover:bg-indigo-700"
                  )
                ]}
              >
                {if @polling, do: "Exporting...", else: "Start Export"}
              </button>
            </div>
          </form>
        </div>

        <div :if={@export} class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Export Status</h2>
          <dl class="grid grid-cols-2 gap-4">
            <div>
              <dt class="text-sm font-medium text-gray-500">Status</dt>
              <dd class="mt-1">
                <span class={[
                  "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium",
                  export_status_class(@export.status)
                ]}>
                  {@export.status}
                </span>
              </dd>
            </div>
            <div>
              <dt class="text-sm font-medium text-gray-500">Format</dt>
              <dd class="mt-1 text-sm text-gray-900 uppercase">{@export.format}</dd>
            </div>
            <div :if={@export.completed_at}>
              <dt class="text-sm font-medium text-gray-500">Completed At</dt>
              <dd class="mt-1 text-sm text-gray-900">
                {Calendar.strftime(@export.completed_at, "%Y-%m-%d %H:%M")}
              </dd>
            </div>
            <div :if={@export.status == "completed" && @export.file_path}>
              <dt class="text-sm font-medium text-gray-500">Download</dt>
              <dd class="mt-1">
                <a
                  href={export_download_url(@export)}
                  target="_blank"
                  class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
                >
                  Download CSV
                </a>
              </dd>
            </div>
            <div :if={@export.error}>
              <dt class="text-sm font-medium text-gray-500">Error</dt>
              <dd class="mt-1 text-sm text-red-600">{@export.error}</dd>
            </div>
          </dl>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp export_download_url(%{file_path: "r2://" <> key}) do
    Spectabas.R2.presigned_url(key)
  end

  defp export_download_url(%{file_path: path}) when is_binary(path), do: path

  defp export_status_class("pending"), do: "bg-yellow-100 text-yellow-800"
  defp export_status_class("completed"), do: "bg-green-100 text-green-800"
  defp export_status_class("failed"), do: "bg-red-100 text-red-800"
  defp export_status_class(_), do: "bg-gray-100 text-gray-800"
end
