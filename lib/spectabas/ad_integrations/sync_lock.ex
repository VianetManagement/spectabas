defmodule Spectabas.AdIntegrations.SyncLock do
  @moduledoc """
  Cross-instance lock using Postgres advisory locks to prevent concurrent syncs
  for the same integration. Works across horizontally scaled instances.
  Falls back to local persistent_term as a fast check to avoid unnecessary DB calls.
  """

  @ttl_seconds 300

  def locked?(key) do
    # Fast local check first
    case :persistent_term.get({__MODULE__, key}, nil) do
      nil -> false
      ts -> System.monotonic_time(:second) - ts < @ttl_seconds
    end
  end

  def acquire(key) do
    lock_id = advisory_lock_id(key)

    case Spectabas.Repo.query("SELECT pg_try_advisory_lock($1)", [lock_id]) do
      {:ok, %{rows: [[true]]}} ->
        :persistent_term.put({__MODULE__, key}, System.monotonic_time(:second))
        true

      _ ->
        false
    end
  end

  def release(key) do
    lock_id = advisory_lock_id(key)
    Spectabas.Repo.query("SELECT pg_advisory_unlock($1)", [lock_id])
    :persistent_term.erase({__MODULE__, key})
  catch
    _, _ -> :ok
  end

  # Convert any key into a stable int64 for Postgres advisory lock
  defp advisory_lock_id(key) do
    :erlang.phash2(key, 2_147_483_647)
  end
end
