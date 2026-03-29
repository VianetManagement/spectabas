defmodule Spectabas.Sites.DomainCache do
  @moduledoc """
  ETS-backed cache for domain -> site and public_key -> site lookups.
  Warms from the database on startup. Both caches are updated together.
  """

  use GenServer

  @domain_table :spectabas_domain_cache
  @key_table :spectabas_key_cache

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a site by domain. Returns `{:ok, site}` or `:error`.
  """
  def lookup(domain) when is_binary(domain) do
    case :ets.lookup(@domain_table, domain) do
      [{^domain, site}] -> {:ok, site}
      [] -> :error
    end
  end

  @doc """
  Look up a site by public_key. Returns `{:ok, site}` or `:error`.
  Used by the collection endpoint hot path.
  """
  def lookup_by_key(key) when is_binary(key) do
    case :ets.lookup(@key_table, key) do
      [{^key, site}] -> {:ok, site}
      [] -> :error
    end
  end

  @doc """
  Insert or update a site in both caches.
  """
  def put(%{domain: domain, public_key: key} = site) do
    :ets.insert(@domain_table, {domain, site})
    if key, do: :ets.insert(@key_table, {key, site})
    :ok
  end

  @doc """
  Remove a site from both caches.
  """
  def delete(domain) when is_binary(domain) do
    case :ets.lookup(@domain_table, domain) do
      [{_, %{public_key: key}}] when not is_nil(key) -> :ets.delete(@key_table, key)
      _ -> :ok
    end

    :ets.delete(@domain_table, domain)
    :ok
  end

  @doc """
  Warm the cache by loading all active sites from the database.
  """
  def warm do
    GenServer.cast(__MODULE__, :warm)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :ets.new(@domain_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@key_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}, {:continue, :warm}}
  end

  @impl true
  def handle_continue(:warm, state) do
    do_warm()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:warm, state) do
    do_warm()
    {:noreply, state}
  end

  defp do_warm do
    import Ecto.Query
    alias Spectabas.Repo
    alias Spectabas.Sites.Site

    sites = Repo.all(from s in Site, where: s.active == true)

    Enum.each(sites, fn site ->
      :ets.insert(@domain_table, {site.domain, site})
      if site.public_key, do: :ets.insert(@key_table, {site.public_key, site})
    end)
  end
end
