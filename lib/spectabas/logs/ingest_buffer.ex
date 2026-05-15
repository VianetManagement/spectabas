defmodule Spectabas.Logs.IngestBuffer do
  @moduledoc """
  Buffer for server-log rows en route to ClickHouse. Modeled on
  `Spectabas.Events.IngestBuffer` but kept separate so heavy log
  bursts don't contend with event-ingest buffering. Same pattern:

  - GenServer accepts rows via `push/1` / `push_batch/1`
  - Flushes every `@flush_interval_ms` OR when batch >= `@max_batch_size`
  - Async flush via Task.Supervisor — never blocks on CH I/O
  - Trapped exit flushes remaining buffer on shutdown

  Bounded by `@max_buffer_size`. Above the soft limit (`full?/0` true),
  the controller starts shedding load by returning 503 on the ingest
  endpoint — better than queueing forever.
  """

  use GenServer
  require Logger

  alias Spectabas.Logs

  @flush_interval_ms 1_000
  @max_batch_size 500
  @max_buffer_size 20_000
  @soft_limit 10_000
  @ets_table :logs_ingest_buffer_counter

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push a single normalized log row (from Logs.parse_and_normalize/2)."
  def push(row) when is_map(row) do
    GenServer.cast(__MODULE__, {:push_batch, [row]})
  end

  @doc "Push many normalized rows in one shot — cheaper than N pushes."
  def push_batch(rows) when is_list(rows) do
    GenServer.cast(__MODULE__, {:push_batch, rows})
  end

  def flush, do: GenServer.call(__MODULE__, :flush)

  def full? do
    case :ets.lookup(@ets_table, :size) do
      [{:size, n}] -> n >= @soft_limit
      _ -> false
    end
  end

  def buffer_size do
    case :ets.lookup(@ets_table, :size) do
      [{:size, n}] -> n
      _ -> 0
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :public, :set])
    :ets.insert(@ets_table, {:size, 0})
    Process.flag(:trap_exit, true)
    schedule_flush()
    {:ok, %{buffer: []}}
  end

  @impl true
  def handle_cast({:push_batch, rows}, %{buffer: buf} = state) when is_list(rows) do
    rows = Enum.reject(rows, &is_nil/1)

    if rows == [] do
      {:noreply, state}
    else
      new_buf = buf ++ rows
      new_size = length(new_buf)
      :ets.insert(@ets_table, {:size, new_size})

      cond do
        new_size >= @max_buffer_size ->
          # Backpressure — drop oldest, keep newest. Better than OOM.
          dropped = new_size - @max_buffer_size
          Logger.warning("[LogsBuffer] dropping #{dropped} oldest rows (hard limit hit)")
          trimmed = Enum.take(new_buf, -@max_buffer_size)
          :ets.insert(@ets_table, {:size, length(trimmed)})
          {:noreply, %{state | buffer: trimmed}}

        new_size >= @max_batch_size ->
          spawn_flush(new_buf)
          :ets.insert(@ets_table, {:size, 0})
          {:noreply, %{state | buffer: []}}

        true ->
          {:noreply, %{state | buffer: new_buf}}
      end
    end
  end

  @impl true
  def handle_call(:flush, _from, %{buffer: buf} = state) do
    if buf != [] do
      spawn_flush(buf)
      :ets.insert(@ets_table, {:size, 0})
    end

    {:reply, :ok, %{state | buffer: []}}
  end

  @impl true
  def handle_info(:tick, %{buffer: buf} = state) do
    schedule_flush()

    if buf != [] do
      spawn_flush(buf)
      :ets.insert(@ets_table, {:size, 0})
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{buffer: buf}) do
    if buf != [] do
      Logger.notice("[LogsBuffer] flushing #{length(buf)} rows on shutdown")
      Logs.insert_batch(buf)
    end

    :ok
  end

  defp schedule_flush, do: Process.send_after(self(), :tick, @flush_interval_ms)

  defp spawn_flush(rows) do
    Task.Supervisor.start_child(Spectabas.IngestFlushSupervisor, fn ->
      case Logs.insert_batch(rows) do
        {:ok, _} ->
          :ok

        other ->
          Logger.warning("[LogsBuffer] insert failed: #{inspect(other)} (#{length(rows)} rows)")
      end
    end)
  end
end
