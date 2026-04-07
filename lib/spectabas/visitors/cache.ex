defmodule Spectabas.Visitors.Cache do
  @moduledoc "ETS cache for visitor cookie_id → visitor_id mappings. TTL-based expiry with periodic sweep."

  use GenServer

  @table :visitor_cache
  @ttl_seconds 3600
  @sweep_interval_ms 30 * 60 * 1000

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get(site_id, cookie_id) do
    key = {site_id, cookie_id}

    case :ets.lookup(@table, key) do
      [{^key, visitor_id, inserted_at}] ->
        if System.monotonic_time(:second) - inserted_at < @ttl_seconds do
          visitor_id
        else
          :ets.delete(@table, key)
          nil
        end

      _ ->
        nil
    end
  end

  def put(site_id, cookie_id, visitor_id) do
    :ets.insert(@table, {{site_id, cookie_id}, visitor_id, System.monotonic_time(:second)})
  end

  def size, do: :ets.info(@table, :size)

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_expired do
    cutoff = System.monotonic_time(:second) - @ttl_seconds
    before = :ets.info(@table, :size)

    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    after_size = :ets.info(@table, :size)
    evicted = before - after_size

    if evicted > 0 do
      require Logger
      Logger.info("[VisitorCache] Sweep: evicted #{evicted} expired entries, #{after_size} remaining")
    end
  end
end
