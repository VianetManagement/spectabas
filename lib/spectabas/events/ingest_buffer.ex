defmodule Spectabas.Events.IngestBuffer do
  @moduledoc """
  GenServer that buffers incoming events and flushes them to ClickHouse
  in batches. Flush triggers on timer (configurable, default 500ms) or
  when batch size is reached (configurable, default 1000).

  Flushes are performed asynchronously via Task.Supervisor so the GenServer
  is never blocked on ClickHouse I/O and can continue accepting events.

  On ClickHouse failure, events are sent to DeadLetter.
  On success, broadcasts to PubSub "site:{id}" topics grouped by site_id.

  Traps exits for graceful shutdown — flushes remaining buffer on terminate.
  """

  use GenServer
  require Logger

  alias Spectabas.ClickHouse
  alias Spectabas.Events.{EventSchema, DeadLetter}

  @default_flush_interval_ms 500
  @default_max_batch_size 1_000
  @max_buffer_size 10_000
  @soft_limit 5_000
  @ets_table :ingest_buffer_counter
  # Disk persistence removed for stateless scaling

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push an enriched event map into the buffer."
  def push(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:push, event})
  end

  @doc "Force an immediate flush of the buffer."
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc "Returns true if the buffer is over the soft limit and should reject new events."
  def full? do
    case :ets.lookup(@ets_table, :size) do
      [{:size, n}] -> n >= @soft_limit
      _ -> false
    end
  end

  @doc "Returns the current buffer size."
  def buffer_size do
    case :ets.lookup(@ets_table, :size) do
      [{:size, n}] -> n
      _ -> 0
    end
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    # Trap exits so we can flush remaining buffer on shutdown
    Process.flag(:trap_exit, true)

    # Create ETS table for lock-free size checks from the hot path
    :ets.new(@ets_table, [:named_table, :public, :set])
    :ets.insert(@ets_table, {:size, 0})

    cfg = Application.get_env(:spectabas, __MODULE__, [])
    flush_interval = cfg[:flush_interval_ms] || @default_flush_interval_ms
    max_batch = cfg[:max_batch_size] || @default_max_batch_size

    schedule_flush(flush_interval)

    {:ok,
     %{
       buffer: [],
       size: 0,
       flush_interval: flush_interval,
       max_batch: max_batch
     }}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    if state.size >= @max_buffer_size do
      # Dead-letter instead of silently dropping
      Logger.warning("[IngestBuffer] Buffer full (#{@max_buffer_size}), dead-lettering event")

      try do
        DeadLetter.enqueue([EventSchema.to_row(event)], "buffer_full")
      rescue
        _ -> :ok
      end

      {:noreply, state}
    else
      new_buffer = [event | state.buffer]
      new_size = state.size + 1
      update_ets_size(new_size)

      if new_size >= state.max_batch do
        async_flush(new_buffer)
        update_ets_size(0)
        {:noreply, %{state | buffer: [], size: 0}}
      else
        {:noreply, %{state | buffer: new_buffer, size: new_size}}
      end
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    if state.size > 0 do
      async_flush(state.buffer)
      update_ets_size(0)
    end

    {:reply, :ok, %{state | buffer: [], size: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.size > 0 do
      async_flush(state.buffer)
      update_ets_size(0)
      clear_crash_file()
      schedule_flush(state.flush_interval)
      {:noreply, %{state | buffer: [], size: 0}}
    else
      schedule_flush(state.flush_interval)
      {:noreply, state}
    end
  end

  def handle_info(:persist_buffer, state), do: {:noreply, state}

  # Ignore Task.Supervisor DOWN messages from completed flush tasks
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # Graceful shutdown — wait for in-flight flushes, then flush remaining buffer
  @impl true
  def terminate(reason, state) do
    # Wait for any in-flight async flush tasks to complete (up to 5s)
    in_flight = Task.Supervisor.children(Spectabas.IngestFlushSupervisor)

    if length(in_flight) > 0 do
      Logger.info("[IngestBuffer] Waiting for #{length(in_flight)} in-flight flushes...")

      Enum.each(in_flight, fn pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
      end)
    end

    if state.size > 0 do
      Logger.info(
        "[IngestBuffer] Shutting down (#{reason}), flushing #{state.size} buffered events"
      )

      # Synchronous flush on shutdown to ensure events are not lost
      do_flush(state.buffer)
    end

    :ok
  end

  # --- Private ---

  defp schedule_flush(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp update_ets_size(size) do
    :ets.insert(@ets_table, {:size, size})
  end

  # Spawn an async task to flush events — GenServer continues immediately
  defp async_flush([]), do: :ok

  defp async_flush(events) do
    Task.Supervisor.start_child(Spectabas.IngestFlushSupervisor, fn ->
      do_flush(events)
    end)
  end

  defp do_flush([]), do: :ok

  defp do_flush(events) do
    # Convert events to rows individually — catch per-event errors so one
    # malformed event doesn't crash the entire batch
    {rows, failed} =
      Enum.reduce(events, {[], 0}, fn event, {acc, fails} ->
        try do
          {[EventSchema.to_row(event) | acc], fails}
        rescue
          e ->
            Logger.warning(
              "[IngestBuffer] EventSchema.to_row failed: #{Exception.message(e) |> String.slice(0, 200)}"
            )

            {acc, fails + 1}
        end
      end)

    rows = Enum.reverse(rows)

    if failed > 0 do
      Logger.warning("[IngestBuffer] Skipped #{failed} malformed events in batch")
    end

    if rows != [] do
      Logger.info("[IngestBuffer] Flushing #{length(rows)} events")

      try do
        case ClickHouse.insert("events", rows) do
          :ok ->
            broadcast_events(events)
            flush_ecommerce_events(events)
            Logger.info("[IngestBuffer] Flushed #{length(rows)} events OK")

          {:error, reason} ->
            Logger.error(
              "[IngestBuffer] ClickHouse insert FAILED: #{inspect(String.slice(to_string(reason), 0, 500))}"
            )

            DeadLetter.enqueue(rows, reason)
        end
      rescue
        e ->
          Logger.error(
            "[IngestBuffer] ClickHouse insert CRASHED: #{Exception.message(e) |> String.slice(0, 300)}"
          )

          DeadLetter.enqueue(rows, Exception.message(e))
      end
    end
  end

  defp flush_ecommerce_events(events) do
    ecom_events =
      events
      |> Enum.filter(&(&1[:event_type] in ["ecommerce_order", "ecommerce_item"]))
      |> Enum.map(fn event ->
        props = event[:props] || %{}

        %{
          "site_id" => event[:site_id],
          "visitor_id" => event[:visitor_id] || "",
          "session_id" => event[:session_id] || "",
          "order_id" => props["order_id"] || props[:order_id] || "",
          "revenue" => parse_decimal(props["revenue"] || props[:revenue]),
          "subtotal" => parse_decimal(props["subtotal"] || props[:subtotal]),
          "tax" => parse_decimal(props["tax"] || props[:tax]),
          "shipping" => parse_decimal(props["shipping"] || props[:shipping]),
          "discount" => parse_decimal(props["discount"] || props[:discount]),
          "currency" => props["currency"] || props[:currency] || "USD",
          "items" => Jason.encode!(props["items"] || props[:items] || []),
          "timestamp" => event[:timestamp] |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
        }
      end)

    if ecom_events != [] do
      try do
        case ClickHouse.insert("ecommerce_events", ecom_events) do
          :ok ->
            Logger.info("[IngestBuffer] Wrote #{length(ecom_events)} ecommerce events")

          {:error, reason} ->
            Logger.warning(
              "[IngestBuffer] Ecommerce insert failed: #{inspect(reason) |> String.slice(0, 200)}"
            )
        end
      rescue
        e ->
          Logger.warning(
            "[IngestBuffer] Ecommerce insert crashed: #{Exception.message(e) |> String.slice(0, 200)}"
          )
      end
    end
  end

  defp parse_decimal(nil), do: 0
  defp parse_decimal(n) when is_number(n), do: n

  defp parse_decimal(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp parse_decimal(_), do: 0

  defp broadcast_events(events) do
    events
    |> Enum.group_by(& &1[:site_id])
    |> Enum.each(fn {site_id, site_events} ->
      Phoenix.PubSub.broadcast(
        Spectabas.PubSub,
        "site:#{site_id}",
        {:new_events, site_events}
      )
    end)
  end

  # --- Crash Recovery ---

  # Disk persistence removed for stateless scaling.
  # Buffer flushes every 500ms so max data loss on crash is ~500ms of events.
  defp clear_crash_file, do: :ok
end
