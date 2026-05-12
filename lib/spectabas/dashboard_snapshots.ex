defmodule Spectabas.DashboardSnapshots do
  @moduledoc """
  Postgres-backed snapshots of expensive dashboard widget data, refreshed
  hourly by `Spectabas.Workers.DashboardSnapshot`. The LiveViews read from
  these snapshots for their default date range so they don't fan out N
  ClickHouse queries on every page load. Non-default ranges fall back to
  live ClickHouse queries.

  Each snapshot is keyed by `(site_id, kind)` where `kind` is the page
  identifier (e.g. `"ecommerce"`, `"acquisition"`, `"outbound_links"`).
  The shape of `data` is page-specific JSON.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.DashboardSnapshots.Snapshot

  @doc """
  Fetch a snapshot for a site by kind. Returns `nil` if no snapshot exists.
  """
  def get(site, kind) when is_binary(kind) do
    Repo.one(from(s in Snapshot, where: s.site_id == ^site.id and s.kind == ^kind))
  end

  @doc """
  Upsert a snapshot. `data` is any JSON-encodable map; the worker decides the
  shape per kind. Returns `{:ok, snapshot}` or `{:error, changeset}`.
  """
  def put(site, kind, window_days, data) when is_binary(kind) and is_integer(window_days) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      site_id: site.id,
      kind: kind,
      window_days: window_days,
      data: data,
      refreshed_at: now
    }

    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:window_days, :data, :refreshed_at]},
      conflict_target: [:site_id, :kind]
    )
  end

  @doc """
  Convenience: returns the snapshot's `data` and `refreshed_at` if it exists,
  else `nil`. Use when the caller wants to short-circuit on missing data.
  """
  def fetch(site, kind) do
    case get(site, kind) do
      nil -> nil
      %Snapshot{data: data, refreshed_at: refreshed_at} -> {data, refreshed_at}
    end
  end

  @doc """
  Use a snapshot when the user is on the default range; otherwise fall back to
  a live query. `live_fn` is only invoked on the fallback path so we don't
  duplicate the work when the snapshot is fresh. Returns `{data, refreshed_at}`
  where `refreshed_at` is `nil` for live-queried data.

  Example:
      DashboardSnapshots.with_fallback(site, "outbound_links", "30d", current_range, fn ->
        Analytics.outbound_links(site, user, :month)
      end)
  """
  def with_fallback(site, kind, default_range, current_range, live_fn)
      when is_function(live_fn, 0) do
    if current_range == default_range do
      case fetch(site, kind) do
        {data, refreshed_at} -> {data, refreshed_at}
        nil -> {live_fn.(), nil}
      end
    else
      {live_fn.(), nil}
    end
  end

  @doc """
  Like `with_fallback/5` but unwraps a list snapshot stored under the `"rows"`
  key of the snapshot map. Use for list pages (Outbound Links, Downloads,
  Events) whose `Analytics.*` function returns a bare list of rows.
  """
  def with_fallback_list(site, kind, default_range, current_range, live_fn)
      when is_function(live_fn, 0) do
    case with_fallback(site, kind, default_range, current_range, live_fn) do
      {%{"rows" => rows}, refreshed_at} -> {rows, refreshed_at}
      {data, refreshed_at} when is_list(data) -> {data, refreshed_at}
      {_, refreshed_at} -> {[], refreshed_at}
    end
  end

  @doc """
  Render a "last update Xm ago" style label for a snapshot timestamp.
  Returns nil when `refreshed_at` is nil (live data, no snapshot involved).
  """
  def refreshed_label(nil), do: nil

  def refreshed_label(%DateTime{} = dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      secs < 60 -> "just now"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
