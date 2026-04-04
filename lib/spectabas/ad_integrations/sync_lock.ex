defmodule Spectabas.AdIntegrations.SyncLock do
  @moduledoc """
  Simple process-level lock using persistent_term to prevent concurrent syncs
  for the same integration+date. Shared across all platform adapters.
  """

  @ttl_seconds 300

  def locked?(key) do
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil -> false
      ts -> System.monotonic_time(:second) - ts < @ttl_seconds
    end
  end

  def acquire(key) do
    :persistent_term.put({__MODULE__, key}, System.monotonic_time(:second))
  end

  def release(key) do
    :persistent_term.erase({__MODULE__, key})
  catch
    _, _ -> :ok
  end
end
