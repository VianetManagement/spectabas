defmodule Spectabas.Sites.DomainCache do
  @moduledoc """
  ETS-backed cache for domain -> site lookups.
  Warms from the database on startup.
  """

  use GenServer

  @table :spectabas_domain_cache

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a site by domain. Returns `{:ok, site}` or `:error`.
  """
  def lookup(domain) when is_binary(domain) do
    case :ets.lookup(@table, domain) do
      [{^domain, site}] -> {:ok, site}
      [] -> :error
    end
  end

  @doc """
  Insert or update a site in the cache.
  """
  def put(%{domain: domain} = site) do
    :ets.insert(@table, {domain, site})
    :ok
  end

  @doc """
  Remove a domain from the cache.
  """
  def delete(domain) when is_binary(domain) do
    :ets.delete(@table, domain)
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
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}, {:continue, :warm}}
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
      :ets.insert(@table, {site.domain, site})
    end)
  end
end
