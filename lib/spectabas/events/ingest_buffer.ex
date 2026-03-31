defmodule Spectabas.Events.IngestBuffer do
  @moduledoc """
  GenServer that buffers incoming events and flushes them to ClickHouse
  in batches. Flush triggers on timer (configurable, default 500ms) or
  when batch size is reached (configurable, default 200).

  On ClickHouse failure, events are sent to DeadLetter.
  On success, broadcasts to PubSub "site:{id}" topics grouped by site_id.

  Traps exits for graceful shutdown — flushes remaining buffer on terminate.
  """

  use GenServer
  require Logger

  alias Spectabas.ClickHouse
  alias Spectabas.Events.{EventSchema, DeadLetter}

  @default_flush_interval_ms 500
  @default_max_batch_size 200
  @max_buffer_size 10_000
  @soft_limit 5_000
  @ets_table :ingest_buffer_counter

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
        do_flush(new_buffer)
        update_ets_size(0)
        {:noreply, %{state | buffer: [], size: 0}}
      else
        {:noreply, %{state | buffer: new_buffer, size: new_size}}
      end
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush(state.buffer)
    update_ets_size(0)
    {:reply, :ok, %{state | buffer: [], size: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    if state.size > 0 do
      do_flush(state.buffer)
      update_ets_size(0)
      schedule_flush(state.flush_interval)
      {:noreply, %{state | buffer: [], size: 0}}
    else
      schedule_flush(state.flush_interval)
      {:noreply, state}
    end
  end

  # Graceful shutdown — flush remaining buffer before dying
  @impl true
  def terminate(reason, state) do
    if state.size > 0 do
      Logger.info(
        "[IngestBuffer] Shutting down (#{reason}), flushing #{state.size} buffered events"
      )

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

      case ClickHouse.insert("events", rows) do
        :ok ->
          broadcast_events(events)
          Logger.info("[IngestBuffer] Flushed #{length(rows)} events OK")

        {:error, reason} ->
          Logger.error(
            "[IngestBuffer] ClickHouse insert FAILED: #{inspect(String.slice(to_string(reason), 0, 500))}"
          )

          DeadLetter.enqueue(rows, reason)
      end
    end
  end

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
end
