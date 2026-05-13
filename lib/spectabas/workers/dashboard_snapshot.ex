defmodule Spectabas.Workers.DashboardSnapshot do
  @moduledoc """
  Hourly snapshot of expensive dashboard widget data into Postgres so dashboard
  pages don't fan out N ClickHouse queries on every page load.

  Each LiveView checks for a snapshot at its default range; if present, renders
  from PG. If absent or if the user picks a non-default range, the LiveView
  falls back to live ClickHouse.

  Modes:
  - no args → enqueue a per-site job for every site
  - `%{"site_id" => N}` → snapshot one site (runs every page's snapshot
    function, each isolated in its own try block so one failure doesn't take
    down the others)

  All Analytics calls use a synthetic platform_admin user so the existing
  `authorize/2` gate passes without needing per-function `_system` variants.
  This is safe: the worker is server-only and only reads aggregated data.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger
  alias Spectabas.{Accounts, Analytics, DashboardSnapshots, Goals, Sites, Visitors}

  @impl Oban.Worker
  # 25 min — per-goal detail snapshots dominate runtime on sites with many
  # goals. Click-element goal queries (JSONExtractString full scan) can take
  # close to the 90s CH max we set, so 16 goals × ~90s worst case = ~24 min.
  def timeout(_job), do: :timer.seconds(1500)

  @default_outbound_window 30
  @default_downloads_window 30
  @default_events_window 30
  @default_site_search_window 30
  @default_bot_traffic_window 7
  @default_acquisition_window 7
  @default_ecommerce_window 7
  @default_suggested_funnels_window 30

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"site_id" => site_id}}) do
    case Sites.get_site(site_id) do
      nil -> :ok
      site -> snapshot_site(site)
    end
  end

  def perform(%Oban.Job{args: args}) when args == %{} do
    Sites.list_sites()
    |> Enum.each(fn site ->
      __MODULE__.new(%{"site_id" => site.id}) |> Oban.insert()
    end)

    :ok
  end

  defp snapshot_site(site) do
    user = system_user(site)

    snapshot_kind(site, "outbound_links", @default_outbound_window, fn ->
      %{"rows" => list_or_empty(Analytics.outbound_links(site, user, :month))}
    end)

    snapshot_kind(site, "downloads", @default_downloads_window, fn ->
      %{"rows" => list_or_empty(Analytics.file_downloads(site, user, :month))}
    end)

    snapshot_kind(site, "events", @default_events_window, fn ->
      %{"rows" => list_or_empty(Analytics.custom_events(site, user, :month))}
    end)

    snapshot_kind(site, "site_search", @default_site_search_window, fn ->
      stats =
        case Analytics.site_search_stats(site, user, :month) do
          {:ok, [row | _]} -> row
          _ -> %{}
        end

      trend =
        case Analytics.site_search_trend(site, user, :month) do
          {:ok, rows} -> rows
          _ -> []
        end

      pages =
        case Analytics.site_search_pages(site, user, :month) do
          {:ok, rows} -> rows
          _ -> []
        end

      searches =
        case Analytics.site_searches(site, user, :month) do
          {:ok, rows} -> rows
          _ -> []
        end

      params =
        case Analytics.site_search_params_used(site, user, :month) do
          {:ok, rows} -> rows
          _ -> []
        end

      %{
        "stats" => stats,
        "trend" => trend,
        "pages" => pages,
        "searches" => searches,
        "params_used" => params
      }
    end)

    snapshot_kind(site, "bot_traffic", @default_bot_traffic_window, fn ->
      stats =
        case Analytics.bot_stats(site, user, :week) do
          {:ok, data} -> data
          _ -> %{}
        end

      top_pages =
        case Analytics.bot_top_pages(site, user, :week) do
          {:ok, rows} -> rows
          _ -> []
        end

      top_uas =
        case Analytics.bot_top_user_agents(site, user, :week) do
          {:ok, rows} -> rows
          _ -> []
        end

      daily_trend =
        case Analytics.bot_daily_trend(site, user, :week) do
          {:ok, rows} -> rows
          _ -> []
        end

      %{
        "stats" => stats,
        "top_pages" => top_pages,
        "top_uas" => top_uas,
        "daily_trend" => daily_trend
      }
    end)

    snapshot_kind(site, "acquisition", @default_acquisition_window, fn ->
      snapshot_acquisition(site, user)
    end)

    snapshot_kind(site, "ecommerce", @default_ecommerce_window, fn ->
      snapshot_ecommerce(site, user)
    end)

    snapshot_kind(site, "suggested_funnels", @default_suggested_funnels_window, fn ->
      %{"rows" => list_or_empty(Analytics.suggested_funnels(site, user))}
    end)

    # Per-goal detail snapshot. Stored as `goal_detail:<goal_id>` so the
    # detail page renders instantly when the user clicks into a goal. 30d
    # window matches the page default; other ranges fall back to live CH.
    Goals.list_goals(site)
    |> Enum.each(fn goal ->
      snapshot_kind(site, "goal_detail:#{goal.id}", 30, fn ->
        snapshot_goal_detail(site, user, goal)
      end)
    end)

    :ok
  end

  defp snapshot_goal_detail(site, user, goal) do
    tasks = %{
      stats:
        Task.async(fn ->
          case Analytics.goal_detail_stats(site, user, goal, "30d") do
            {:ok, m} -> m
            _ -> %{}
          end
        end),
      timeseries:
        Task.async(fn ->
          list_or_empty(Analytics.goal_completion_timeseries(site, user, goal, "30d"))
        end),
      sources:
        Task.async(fn ->
          list_or_empty(Analytics.goal_source_attribution(site, user, goal, "30d"))
        end),
      pages:
        Task.async(fn -> list_or_empty(Analytics.goal_top_pages(site, user, goal, "30d")) end),
      devices:
        Task.async(fn ->
          list_or_empty(Analytics.goal_device_breakdown(site, user, goal, "30d"))
        end),
      geo:
        Task.async(fn -> list_or_empty(Analytics.goal_geo_breakdown(site, user, goal, "30d")) end),
      completers:
        Task.async(fn ->
          list_or_empty(Analytics.goal_recent_completers(site, user, goal, "30d"))
        end)
    }

    results = Map.new(tasks, fn {k, t} -> {k, Task.await(t, 60_000)} end)

    # Resolve emails now so the LiveView doesn't need a second PG trip.
    visitor_ids =
      results.completers
      |> Enum.map(& &1["visitor_id"])
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    email_map =
      visitor_ids
      |> Spectabas.Visitors.emails_for_visitor_ids()
      |> Map.new(fn {vid, %{email: email}} -> {to_string(vid), email} end)

    click_info =
      if goal.goal_type == "click_element" do
        case Analytics.goal_click_element_details(site, user, goal) do
          {:ok, [info | _]} -> info
          _ -> nil
        end
      end

    %{
      "stats" => stats_to_string_keys(results.stats),
      "timeseries" => results.timeseries,
      "top_sources" => Enum.take(results.sources, 10),
      "top_pages" => results.pages,
      "devices" => results.devices,
      "geo" => results.geo,
      "recent_completers" => results.completers,
      "email_map" => email_map,
      "click_element_info" => click_info
    }
  end

  defp stats_to_string_keys(stats) when is_map(stats) do
    Map.new(stats, fn {k, v} -> {to_string(k), v} end)
  end

  defp stats_to_string_keys(_), do: %{}

  defp snapshot_kind(site, kind, window_days, fun) do
    started = System.monotonic_time(:millisecond)

    try do
      data = normalize(fun.())

      case DashboardSnapshots.put(site, kind, window_days, data) do
        {:ok, _} ->
          ms = System.monotonic_time(:millisecond) - started

          Logger.notice(
            "[DashboardSnapshot] site=#{site.id} kind=#{kind} window=#{window_days}d took=#{ms}ms"
          )

          :ok

        {:error, %Ecto.Changeset{errors: errors}} ->
          Logger.error(
            "[DashboardSnapshot] site=#{site.id} kind=#{kind} changeset_failed: #{inspect(errors)} data_shape=#{shape(data)}"
          )

          :ok

        {:error, reason} ->
          Logger.error(
            "[DashboardSnapshot] site=#{site.id} kind=#{kind} put_failed: #{inspect(reason)}"
          )

          :ok
      end
    rescue
      e ->
        Logger.error(
          "[DashboardSnapshot] site=#{site.id} kind=#{kind} crashed: #{Exception.message(e)}"
        )

        :ok
    end
  end

  defp shape(data) when is_map(data),
    do: "map(keys=#{data |> Map.keys() |> Enum.take(8) |> inspect()})"

  defp shape(data) when is_list(data), do: "list(len=#{length(data)})"
  defp shape(_), do: "other"

  # Acquisition: channel breakdown + each source tab + source_engagement per
  # dimension (so the LiveView can render any tab from the snapshot).
  defp snapshot_acquisition(site, user) do
    channels =
      case Analytics.channel_breakdown(site, user, :week) do
        {:ok, rows} -> rows
        _ -> []
      end

    referrers = list_or_empty(Analytics.top_sources(site, user, :week))
    utm_sources = list_or_empty(Analytics.top_utm_sources(site, user, :week))
    utm_mediums = list_or_empty(Analytics.top_utm_mediums(site, user, :week))
    utm_campaigns = list_or_empty(Analytics.top_utm_campaigns(site, user, :week))
    utm_terms = list_or_empty(Analytics.top_utm_terms(site, user, :week))
    utm_content = list_or_empty(Analytics.top_utm_content(site, user, :week))

    engagement_by_dim =
      ["referrer_domain", "utm_source", "utm_medium", "utm_campaign"]
      |> Enum.reduce(%{}, fn dim, acc ->
        case Analytics.source_engagement(site, user, :week, dim) do
          {:ok, map} -> Map.put(acc, dim, normalize_engagement(map))
          _ -> acc
        end
      end)

    %{
      "channels" => channels,
      "referrers" => referrers,
      "utm_source" => utm_sources,
      "utm_medium" => utm_mediums,
      "utm_campaign" => utm_campaigns,
      "utm_term" => utm_terms,
      "utm_content" => utm_content,
      "engagement" => engagement_by_dim
    }
  end

  # Engagement map has atom-keyed structs; convert to string keys for JSONB.
  defp normalize_engagement(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {k,
       %{
         "bounce_rate" => Map.get(v, :bounce_rate),
         "avg_duration" => Map.get(v, :avg_duration),
         "pages_per_session" => Map.get(v, :pages_per_session)
       }}
    end)
  end

  defp normalize_engagement(_), do: %{}

  defp snapshot_ecommerce(site, user) do
    stats = ok_or(Analytics.ecommerce_stats(site, user, :week), %{})
    products = list_or_empty(Analytics.ecommerce_top_products(site, user, :week))
    orders = list_or_empty(Analytics.ecommerce_orders(site, user, :week))
    timeseries = list_or_empty(Analytics.ecommerce_timeseries(site, user, :week))
    by_channel = list_or_empty(Analytics.ecommerce_by_channel(site, user, :week))
    by_source = list_or_empty(Analytics.ecommerce_by_source(site, user, :week))
    ltv = ok_or(Analytics.ecommerce_ltv_stats(site, user), %{})
    top_customers = list_or_empty(Analytics.ecommerce_top_customers(site, user, limit: 10))

    # Resolve emails for orders + top customers now so the LiveView doesn't
    # need to do a second Postgres trip on every page load.
    visitor_ids =
      (Enum.map(orders, &Map.get(&1, "visitor_id")) ++
         Enum.map(top_customers, &Map.get(&1, "visitor_id")))
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()

    email_map =
      visitor_ids
      |> Visitors.emails_for_visitor_ids()
      |> Map.new(fn {vid, %{email: email}} -> {to_string(vid), email} end)

    %{
      "stats" => stats,
      "top_products" => products,
      "orders" => orders,
      "timeseries" => timeseries,
      "by_channel" => by_channel,
      "by_source" => by_source,
      "ltv" => ltv,
      "top_customers" => top_customers,
      "email_map" => email_map
    }
  end

  defp list_or_empty({:ok, rows}) when is_list(rows), do: rows
  defp list_or_empty(_), do: []

  defp ok_or({:ok, data}, _default), do: data
  defp ok_or(_, default), do: default

  # The `data` JSONB column is typed as `:map` in Ecto — lists fail to cast.
  # Snapshot blocks must return a map; wrap raw lists in %{"rows" => ...}.
  defp normalize({:ok, data}), do: normalize(data)
  defp normalize(data) when is_map(data), do: data
  defp normalize(data) when is_list(data), do: %{"rows" => data}
  defp normalize(_), do: %{}

  defp system_user(site) do
    %Accounts.User{
      id: 0,
      role: :platform_admin,
      account_id: site.account_id
    }
  end
end
