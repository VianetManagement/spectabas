defmodule Spectabas.Visitors.Cache do
  @moduledoc "ETS cache for visitor cookie_id → visitor_id mappings. TTL-based expiry."

  @table :visitor_cache
  @ttl_seconds 3600

  def init do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
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
end
