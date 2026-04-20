defmodule SpectabasWeb.Admin.IngestDiagnosticsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.Events.IngestBuffer
  alias Spectabas.Visitors.Cache, as: VisitorCache
  alias Spectabas.Accounts
  import Spectabas.TypeHelpers

  @refresh_ms 10_000

  @timezones [
    "America/New_York",
    "America/Chicago",
    "America/Denver",
    "America/Los_Angeles",
    "America/Phoenix",
    "America/Anchorage",
    "Pacific/Honolulu",
    "UTC",
    "Europe/London",
    "Europe/Paris",
    "Europe/Berlin",
    "Asia/Tokyo",
    "Asia/Shanghai",
    "Australia/Sydney"
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()
    user = socket.assigns.current_scope.user
    tz = user.timezone || "America/New_York"

    {:ok,
     socket
     |> assign(:page_title, "Ingest Diagnostics")
     |> assign(:user, user)
     |> assign(:timezone, tz)
     |> assign(:timezones, @timezones)
     |> load_slow_metrics()
     |> load_live_metrics()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load_live_metrics(socket)}
  end

  @impl true
  def handle_event("change_timezone", %{"timezone" => tz}, socket) do
    Accounts.update_user_timezone(socket.assigns.user, tz)
    {:noreply, assign(socket, :timezone, tz)}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  # Heavy queries — run once on mount
  defp load_slow_metrics(socket) do
    ch_status = check_ch_status()

    events_today =
      if ch_status == :ok do
        case Spectabas.ClickHouse.query(
               "SELECT count() AS c FROM events WHERE toDate(timestamp) = today()"
             ) do
          {:ok, [%{"c" => c}]} -> to_num(c)
          _ -> 0
        end
      else
        0
      end

    click_id_stats =
      if ch_status == :ok do
        case Spectabas.ClickHouse.query("""
             SELECT click_id_type, count() AS events, uniq(visitor_id) AS visitors
             FROM events
             WHERE click_id != '' AND click_id_type != '' AND timestamp >= now() - INTERVAL 7 DAY
             GROUP BY click_id_type ORDER BY events DESC
             """) do
          {:ok, rows} -> rows
          _ -> []
        end
      else
        []
      end

    click_id_today =
      if ch_status == :ok do
        case Spectabas.ClickHouse.query(
               "SELECT count() AS c FROM events WHERE click_id != '' AND toDate(timestamp) = today()"
             ) do
          {:ok, [%{"c" => c}]} -> to_num(c)
          _ -> 0
        end
      else
        0
      end

    socket
    |> assign(:events_today, events_today)
    |> assign(:click_id_stats, click_id_stats)
    |> assign(:click_id_today, click_id_today)
  end

  # Lightweight metrics — run every refresh tick
  defp load_live_metrics(socket) do
    buffer_size = IngestBuffer.buffer_size()
    buffer_full = IngestBuffer.full?()
    cache_size = VisitorCache.size()

    memory = :erlang.memory()
    process_count = :erlang.system_info(:process_count)
    scheduler_count = :erlang.system_info(:schedulers_online)
    {reductions, _} = :erlang.statistics(:reductions)
    {{_, io_in}, {_, io_out}} = :erlang.statistics(:io)
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)
    run_queue = :erlang.statistics(:total_run_queue_lengths_all)

    ch_status = check_ch_status()

    events_per_min =
      if ch_status == :ok do
        case Spectabas.ClickHouse.query("""
             SELECT toStartOfMinute(timestamp) AS minute, count() AS events
             FROM events WHERE timestamp >= now() - INTERVAL 5 MINUTE
             GROUP BY minute ORDER BY minute
             """) do
          {:ok, rows} -> rows
          _ -> []
        end
      else
        []
      end

    failed_count =
      try do
        Spectabas.Repo.aggregate(Spectabas.Events.FailedEvent, :count, :id)
      rescue
        _ -> 0
      end

    flush_tasks =
      case Task.Supervisor.children(Spectabas.IngestFlushSupervisor) do
        pids when is_list(pids) -> length(pids)
        _ -> 0
      end

    import Ecto.Query

    oban_pending =
      try do
        Spectabas.ObanRepo.aggregate(
          from(j in "oban_jobs", where: j.state in ["available", "scheduled", "retryable"]),
          :count
        )
      rescue
        _ -> 0
      end

    oban_executing =
      try do
        Spectabas.ObanRepo.aggregate(
          from(j in "oban_jobs", where: j.state == "executing"),
          :count
        )
      rescue
        _ -> 0
      end

    oban_by_queue =
      try do
        Spectabas.ObanRepo.all(
          from(j in "oban_jobs",
            where: j.state == "executing",
            group_by: [j.queue, j.worker],
            select: %{queue: j.queue, worker: j.worker, count: count(j.id)},
            order_by: [desc: count(j.id)]
          )
        )
      rescue
        _ -> []
      end

    web_pool = db_pool_stats(Spectabas.Repo)
    oban_pool = db_pool_stats(Spectabas.ObanRepo)

    tz = socket.assigns[:timezone] || "America/New_York"

    events_per_min =
      Enum.map(events_per_min, fn row ->
        Map.update(row, "minute", "", &convert_to_tz(&1, tz))
      end)

    socket
    |> assign(:buffer_size, buffer_size)
    |> assign(:buffer_full, buffer_full)
    |> assign(:cache_size, cache_size)
    |> assign(:memory_total, div(memory[:total], 1_048_576))
    |> assign(:memory_processes, div(memory[:processes], 1_048_576))
    |> assign(:memory_ets, div(memory[:ets], 1_048_576))
    |> assign(:process_count, process_count)
    |> assign(:scheduler_count, scheduler_count)
    |> assign(:reductions, reductions)
    |> assign(:io_in_mb, div(io_in, 1_048_576))
    |> assign(:io_out_mb, div(io_out, 1_048_576))
    |> assign(:uptime_hours, div(uptime_ms, 3_600_000))
    |> assign(:run_queue, run_queue)
    |> assign(:ch_status, ch_status)
    |> assign(:events_per_min, events_per_min)
    |> assign(:failed_count, failed_count)
    |> assign(:flush_tasks, flush_tasks)
    |> assign(:oban_pending, oban_pending)
    |> assign(:oban_executing, oban_executing)
    |> assign(:oban_by_queue, oban_by_queue)
    |> assign(:web_pool, web_pool)
    |> assign(:oban_pool, oban_pool)
  end

  defp check_ch_status do
    if Process.whereis(Spectabas.ClickHouse) do
      case Spectabas.ClickHouse.query("SELECT 1 AS ok") do
        {:ok, _} -> :ok
        _ -> :error
      end
    else
      :not_started
    end
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

      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 class="text-2xl font-bold text-gray-900">Ingest Diagnostics</h1>
          <p class="text-sm text-gray-500 mt-1">Live metrics — refreshes every 10 seconds</p>
        </div>
        <div class="flex items-center gap-3">
          <form phx-change="change_timezone" class="flex items-center gap-2">
            <label class="text-xs text-gray-500">Timezone:</label>
            <select
              name="timezone"
              class="text-xs border-gray-300 rounded-md shadow-sm py-1 px-2"
            >
              <option :for={tz <- @timezones} value={tz} selected={tz == @timezone}>{tz}</option>
            </select>
          </form>
          <span class="w-2.5 h-2.5 bg-green-500 rounded-full animate-pulse"></span>
        </div>
      </div>

      <%!-- Pipeline Status --%>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        <.metric_card
          label="Buffer Size"
          value={format_number(@buffer_size)}
          color={
            if @buffer_full, do: "red", else: if(@buffer_size > 1000, do: "yellow", else: "green")
          }
          sublabel={if @buffer_full, do: "BACKPRESSURE", else: "of 10,000 max"}
        />
        <.metric_card
          label="Active Flushes"
          value={@flush_tasks}
          color={if @flush_tasks > 8, do: "yellow", else: "green"}
          sublabel="async tasks"
        />
        <.metric_card
          label="Visitor Cache"
          value={format_number(@cache_size)}
          color="blue"
          sublabel="cached lookups (1hr TTL)"
        />
        <.metric_card
          label="Failed Events"
          value={format_number(@failed_count)}
          color={if @failed_count > 0, do: "red", else: "green"}
          sublabel="pending retry"
        />
      </div>

      <%!-- Background Jobs & DB Pools --%>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        <.metric_card
          label="Oban Pending"
          value={format_number(@oban_pending)}
          color={
            cond do
              @oban_pending >= 500_000 -> "red"
              @oban_pending >= 10_000 -> "yellow"
              true -> "green"
            end
          }
          sublabel="queued jobs"
        />
        <.metric_card
          label="Oban Executing"
          value={@oban_executing}
          color="blue"
          sublabel="active workers"
        />
        <.metric_card
          label="Web DB Pool"
          value={"#{@web_pool.pool_size}"}
          color="gray"
          sublabel="connections (Repo)"
        />
        <.metric_card
          label="Oban DB Pool"
          value={"#{@oban_pool.pool_size}"}
          color="gray"
          sublabel="connections (ObanRepo)"
        />
      </div>

      <%!-- Oban Queue Breakdown --%>
      <div :if={@oban_by_queue != []} class="bg-white rounded-lg shadow overflow-x-auto mb-8">
        <div class="px-6 py-4 border-b border-gray-100">
          <h2 class="font-semibold text-gray-900">Oban Executing by Worker</h2>
        </div>
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Queue</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Worker</th>
              <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">Count</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-gray-100">
            <tr :for={row <- @oban_by_queue} class="hover:bg-gray-50">
              <td class="px-4 py-2 text-sm font-mono text-gray-700">{row.queue}</td>
              <td class="px-4 py-2 text-sm font-mono text-gray-600">{row.worker}</td>
              <td class="px-4 py-2 text-sm text-gray-900 text-right tabular-nums font-bold">
                {row.count}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- ClickHouse --%>
      <div class="grid grid-cols-2 md:grid-cols-3 gap-4 mb-8">
        <.metric_card
          label="ClickHouse"
          value={if @ch_status == :ok, do: "Connected", else: "Down"}
          color={if @ch_status == :ok, do: "green", else: "red"}
          sublabel=""
        />
        <.metric_card
          label="Events Today"
          value={format_number(@events_today)}
          color="blue"
          sublabel="all sites"
        />
        <div class="bg-white rounded-lg shadow p-4">
          <dt class="text-xs font-medium text-gray-500 uppercase">Events/Minute (last 5 min)</dt>
          <div class="mt-2 space-y-1">
            <div :for={row <- @events_per_min} class="flex justify-between text-sm">
              <span class="text-gray-500 font-mono text-xs">
                {String.slice(row["minute"] || "", 11, 5)}
              </span>
              <span class="font-bold text-gray-900 tabular-nums">
                {format_number(to_num(row["events"]))}
              </span>
            </div>
            <div :if={@events_per_min == []} class="text-sm text-gray-400">No data</div>
          </div>
        </div>
      </div>

      <%!-- Click ID Attribution --%>
      <h2 class="text-lg font-semibold text-gray-900 mb-4">Click ID Attribution</h2>
      <div class="grid grid-cols-2 md:grid-cols-3 gap-4 mb-8">
        <.metric_card
          label="Click IDs Today"
          value={format_number(@click_id_today)}
          color={if @click_id_today > 0, do: "green", else: "gray"}
          sublabel="events with gclid/msclkid/fbclid"
        />
        <div class="bg-white rounded-lg shadow p-4 md:col-span-2">
          <dt class="text-xs font-medium text-gray-500 uppercase">By Platform (last 7 days)</dt>
          <div class="mt-2 space-y-1.5">
            <div :for={row <- @click_id_stats} class="flex items-center justify-between text-sm">
              <div class="flex items-center gap-2">
                <span class={["w-2 h-2 rounded-full", click_id_color(row["click_id_type"])]}></span>
                <span class="text-gray-700 font-medium">{click_id_label(row["click_id_type"])}</span>
              </div>
              <div class="flex gap-4 tabular-nums">
                <span class="text-gray-900 font-bold">
                  {format_number(to_num(row["events"]))} events
                </span>
                <span class="text-gray-500">{format_number(to_num(row["visitors"]))} visitors</span>
              </div>
            </div>
            <div :if={@click_id_stats == []} class="text-sm text-gray-400">
              No click ID data yet. Events will appear here as visitors arrive from ad clicks with gclid, msclkid, or fbclid parameters.
            </div>
          </div>
        </div>
      </div>

      <%!-- BEAM Runtime --%>
      <h2 class="text-lg font-semibold text-gray-900 mb-4">BEAM Runtime</h2>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
        <.metric_card label="Memory (total)" value={"#{@memory_total} MB"} color="gray" sublabel="" />
        <.metric_card
          label="Memory (processes)"
          value={"#{@memory_processes} MB"}
          color="gray"
          sublabel=""
        />
        <.metric_card label="Memory (ETS)" value={"#{@memory_ets} MB"} color="gray" sublabel="" />
        <.metric_card
          label="Processes"
          value={format_number(@process_count)}
          color="gray"
          sublabel=""
        />
        <.metric_card
          label="Schedulers"
          value={@scheduler_count}
          color="gray"
          sublabel="online"
        />
        <.metric_card
          label="Run Queue"
          value={@run_queue}
          color={if @run_queue > @scheduler_count * 2, do: "yellow", else: "green"}
          sublabel={if @run_queue > @scheduler_count * 2, do: "overloaded", else: "healthy"}
        />
        <.metric_card
          label="I/O In"
          value={"#{@io_in_mb} MB"}
          color="gray"
          sublabel="since boot"
        />
        <.metric_card
          label="Uptime"
          value={"#{@uptime_hours}h"}
          color="gray"
          sublabel=""
        />
      </div>
    </div>
    """
  end

  defp convert_to_tz(timestamp_str, tz) when is_binary(timestamp_str) do
    case NaiveDateTime.from_iso8601(timestamp_str) do
      {:ok, naive} ->
        case DateTime.from_naive(naive, "Etc/UTC") do
          {:ok, utc_dt} ->
            case DateTime.shift_zone(utc_dt, tz) do
              {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M:%S")
              _ -> timestamp_str
            end

          _ ->
            timestamp_str
        end

      _ ->
        # Try space-separated format "2026-03-31 21:44:00"
        case NaiveDateTime.from_iso8601(String.replace(timestamp_str, " ", "T")) do
          {:ok, naive} ->
            case DateTime.from_naive(naive, "Etc/UTC") do
              {:ok, utc_dt} ->
                case DateTime.shift_zone(utc_dt, tz) do
                  {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M:%S")
                  _ -> timestamp_str
                end

              _ ->
                timestamp_str
            end

          _ ->
            timestamp_str
        end
    end
  end

  defp convert_to_tz(other, _tz), do: other

  defp click_id_label("google_ads"), do: "Google Ads (gclid)"
  defp click_id_label("bing_ads"), do: "Microsoft Ads (msclkid)"
  defp click_id_label("meta_ads"), do: "Meta Ads (fbclid)"
  defp click_id_label(other), do: other

  defp click_id_color("google_ads"), do: "bg-blue-500"
  defp click_id_color("bing_ads"), do: "bg-amber-500"
  defp click_id_color("meta_ads"), do: "bg-purple-500"
  defp click_id_color(_), do: "bg-gray-400"

  defp metric_card(assigns) do
    color_class =
      case assigns[:color] do
        "red" -> "text-red-600"
        "yellow" -> "text-yellow-600"
        "green" -> "text-green-600"
        "blue" -> "text-indigo-600"
        _ -> "text-gray-900"
      end

    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <dt class="text-xs font-medium text-gray-500 uppercase">{@label}</dt>
      <dd class={"mt-1 text-2xl font-bold #{@color_class}"}>{@value}</dd>
      <p :if={@sublabel != ""} class="text-xs text-gray-400 mt-0.5">{@sublabel}</p>
    </div>
    """
  end

  defp db_pool_stats(repo) do
    try do
      %{
        pool_size: repo.config()[:pool_size] || 0,
        checked_out: length(DBConnection.get_connection_metrics(repo, :all) || [])
      }
    rescue
      _ -> %{pool_size: repo.config()[:pool_size] || 0, checked_out: 0}
    end
  end
end
