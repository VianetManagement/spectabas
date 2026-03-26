defmodule Spectabas.Sessions.SessionCache do
  @moduledoc """
  ETS-backed GenServer cache for active sessions.
  Keyed by `{site_id, visitor_id}`, entries expire after 30 minutes
  of inactivity. A periodic sweep removes stale entries.
  """

  use GenServer

  @table :spectabas_session_cache
  @sweep_interval_ms 60_000
  @idle_timeout_ms 30 * 60 * 1000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a session for the given `{site_id, visitor_id}` key.
  Returns `{:ok, session_id, last_activity}` or `:miss`.
  """
  def get(cache_key) do
    case :ets.lookup(@table, cache_key) do
      [{^cache_key, session_id, last_activity}] ->
        {:ok, session_id, last_activity}

      [] ->
        :miss
    end
  end

  @doc """
  Store or update a session entry in the cache.
  """
  def put(cache_key, session_id, %DateTime{} = last_activity) do
    :ets.insert(@table, {cache_key, session_id, last_activity})
    :ok
  end

  @doc """
  Update the last_activity timestamp for an existing entry.
  """
  def touch(cache_key, %DateTime{} = now) do
    case :ets.lookup(@table, cache_key) do
      [{^cache_key, session_id, _old}] ->
        :ets.insert(@table, {cache_key, session_id, now})
        :ok

      [] ->
        :miss
    end
  end

  @doc """
  Remove a session entry from the cache.
  """
  def delete(cache_key) do
    :ets.delete(@table, cache_key)
    :ok
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
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

  # --- Private ---

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep_expired do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@idle_timeout_ms, :millisecond)
      |> DateTime.truncate(:second)

    # Scan all entries and delete expired ones
    :ets.foldl(
      fn {key, _session_id, last_activity}, acc ->
        if DateTime.compare(last_activity, cutoff) == :lt do
          :ets.delete(@table, key)
        end

        acc
      end,
      :ok,
      @table
    )
  end
end
