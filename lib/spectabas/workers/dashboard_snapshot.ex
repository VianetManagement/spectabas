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
  @default_pages_window 7
  @default_entry_exit_window 7
  @default_geography_window 7
  @default_devices_window 7
  @default_campaigns_window 30
  @default_performance_window 7
  @default_search_keywords_window 30
  @default_revenue_attribution_window 30
  @default_mrr_window 30

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

    snapshot_kind(site, "pages", @default_pages_window, fn ->
      snapshot_pages(site, user)
    end)

    snapshot_kind(site, "entry_exit", @default_entry_exit_window, fn ->
      snapshot_entry_exit(site, user)
    end)

    snapshot_kind(site, "geography", @default_geography_window, fn ->
      snapshot_geography(site, user)
    end)

    snapshot_kind(site, "devices", @default_devices_window, fn ->
      snapshot_devices(site, user)
    end)

    snapshot_kind(site, "campaigns", @default_campaigns_window, fn ->
      snapshot_campaigns(site, user)
    end)

    snapshot_kind(site, "performance", @default_performance_window, fn ->
      snapshot_performance(site, user)
    end)

    snapshot_kind(site, "search_keywords", @default_search_keywords_window, fn ->
      snapshot_search_keywords(site)
    end)

    snapshot_kind(site, "revenue_attribution", @default_revenue_attribution_window, fn ->
      snapshot_revenue_attribution(site, user)
    end)

    snapshot_kind(site, "mrr", @default_mrr_window, fn ->
      snapshot_mrr(site)
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

  # Pages — top_pages (slow path, full data including avg_duration) + RUM
  # vitals + per-page device split. Stored at default 7d window. Three CH
  # queries on every Pages mount otherwise.
  defp snapshot_pages(site, user) do
    %{
      "pages" => list_or_empty(Analytics.top_pages(site, user, :week)),
      "vitals" => list_or_empty(Analytics.rum_vitals_summary(site, user, :week)),
      "devices" => list_or_empty(Analytics.page_device_split(site, user, :week))
    }
  end

  # Entry/Exit — argMin/argMax(url_path, timestamp) per visitor is the
  # heaviest visitor-grouped pattern in the analytics module.
  defp snapshot_entry_exit(site, user) do
    %{
      "entry_pages" => list_or_empty(Analytics.entry_pages_fast(site, user, :week)),
      "exit_pages" => list_or_empty(Analytics.exit_pages_fast(site, user, :week))
    }
  end

  # Geography — country / region / summary all grouped by ip_country.
  defp snapshot_geography(site, user) do
    %{
      "top_countries" => list_or_empty(Analytics.top_countries(site, user, :week)),
      "top_regions" => list_or_empty(Analytics.top_regions(site, user, :week)),
      "summary" => list_or_empty(Analytics.top_countries_summary(site, user, :week))
    }
  end

  # Devices — browser / OS / device_type aggregations.
  defp snapshot_devices(site, user) do
    %{
      "browsers" => list_or_empty(Analytics.top_browsers(site, user, :week)),
      "os" => list_or_empty(Analytics.top_os(site, user, :week)),
      "device_types" => list_or_empty(Analytics.top_device_types(site, user, :week))
    }
  end

  # Campaigns — UTM campaign performance + engagement + name list. Default
  # range is 30d (not 7d like the others). The engagement map has tuple
  # keys (campaign, source, medium) which don't serialize to JSON; flatten
  # to a list of rows here and let the LiveView rebuild the map on read.
  defp snapshot_campaigns(site, user) do
    engagement_rows =
      case Analytics.campaign_engagement(site, user, :month) do
        {:ok, map} ->
          Enum.map(map, fn {{c, s, m}, %{bounce_rate: br, avg_duration: ad}} ->
            %{
              "campaign" => c,
              "source" => s,
              "medium" => m,
              "bounce_rate" => br,
              "avg_duration" => ad
            }
          end)

        _ ->
          []
      end

    names_rows =
      case Analytics.campaign_names(site, user, :month) do
        {:ok, map} ->
          # campaign_names map is keyed by both campaign_id and campaign_name
          # pointing at the same entry. We rebuild that on read.
          map
          |> Enum.map(fn {k, %{name: n, platform: p}} ->
            %{"key" => k, "name" => n, "platform" => p}
          end)

        _ ->
          []
      end

    %{
      "performance" => list_or_empty(Analytics.campaign_performance_fast(site, user, :month)),
      "engagement" => engagement_rows,
      "names" => names_rows
    }
  end

  # Performance (RUM) — overview + web vitals + per-page + per-device + two
  # timeseries. 6 CH queries on every Performance mount.
  defp snapshot_performance(site, user) do
    %{
      "overview" => ok_or(Analytics.rum_overview(site, user, :week), %{}),
      "vitals" => ok_or(Analytics.rum_web_vitals(site, user, :week), %{}),
      "by_page" => list_or_empty(Analytics.rum_by_page(site, user, :week)),
      "by_device" => list_or_empty(Analytics.rum_by_device(site, user, :week)),
      "vitals_ts" => list_or_empty(Analytics.rum_vitals_timeseries(site, user, :week)),
      "timing_ts" => list_or_empty(Analytics.rum_timing_timeseries(site, user, :week))
    }
  end

  # MRR & Subscriptions — 8 queries from the Spectabas.MRR context module.
  # No date_range param; data is all-time + a 30d MRR trend. Heaviest
  # offender is `subscription_events FINAL` which can have lots of pending
  # parts on busy stores — the context module's ch_query/1 already passes
  # 200_000ms receive_timeout.
  defp snapshot_mrr(site) do
    alias Spectabas.MRR, as: M

    %{
      "revenue_stats" => M.revenue_stats(site),
      "monthly_revenue" => M.monthly_revenue(site),
      "mrr_stats" => M.mrr_stats(site),
      "mrr_trend" => M.mrr_trend(site),
      "plans" => M.plans(site),
      "subscriptions" => M.subscriptions(site),
      "recent_churn" => M.recent_churn(site),
      "renewals_by_month" => M.renewals_by_month(site)
    }
  end

  # Revenue Attribution — 6 queries at the LiveView's default config
  # (30d / group_by=source / touch=last). Other group_by tabs (medium /
  # campaign / term / content) and the first-touch toggle fall through
  # to live CH. `revenue_by_source` and `ad_revenue_by_platform` both
  # do argMin/argMax(channel_expr, timestamp) per visitor — the heaviest
  # attribution pattern in the codebase.
  defp snapshot_revenue_attribution(site, user) do
    rows =
      case Analytics.revenue_by_source(site, user, :month, group_by: "source", touch: "last") do
        {:ok, data} -> data
        _ -> []
      end

    channels =
      case Analytics.revenue_by_channel(site, user, :month) do
        {:ok, data} -> data
        _ -> []
      end

    ad_campaigns =
      case Analytics.ad_spend_by_campaign(site, user, :month) do
        {:ok, data} -> data
        _ -> []
      end

    ad_platforms =
      case Analytics.ad_spend_by_platform(site, user, :month) do
        {:ok, data} -> data
        _ -> []
      end

    ad_totals =
      case Analytics.ad_spend_totals(site, user, :month) do
        {:ok, [row | _]} -> row
        _ -> %{}
      end

    ad_revenue =
      case Analytics.ad_revenue_by_platform(site, user, :month, touch: "last") do
        {:ok, data} -> data
        _ -> []
      end

    %{
      "rows" => rows,
      "channels" => channels,
      "ad_campaigns" => ad_campaigns,
      "ad_platforms" => ad_platforms,
      "ad_totals" => ad_totals,
      "ad_revenue" => ad_revenue
    }
  end

  # Search Keywords — 10 GSC/Bing aggregations at the LiveView's default
  # config (30d, all sources, total_clicks desc) plus sparklines for the
  # top 20 default-sorted queries. Other sort orders / sources / ranges
  # fall through to live CH; the snapshot only covers the default view.
  defp snapshot_search_keywords(site) do
    alias Spectabas.SearchKeywords, as: SK

    {days, source, _sb, _sd} = SK.default_config()
    order = SK.default_order()

    stats = SK.query_stats(site.id, days, source)
    queries = SK.query_top_queries(site.id, days, source, order)
    pages = SK.query_top_pages(site.id, days, source, order)
    ranking_changes = SK.query_ranking_changes(site.id, source)
    opportunity_queue = SK.query_opportunity_queue(site.id, days, source)
    new_keywords = SK.query_new_keywords(site.id, source)
    lost_keywords = SK.query_lost_keywords(site.id, source)
    pos_dist = SK.query_pos_distribution(site.id, days, source)
    daily_trends = SK.query_daily_trends(site.id, days, source)
    cannibalization = SK.query_cannibalization(site.id, days, source)

    top_query_strings = queries |> Enum.take(20) |> Enum.map(& &1["query"])

    # query_sparklines returns %{query => [{bucket, clicks}, ...]} with
    # 2-tuples. Tuples don't serialize to JSON; flatten to [[bucket, clicks]]
    # and the LiveView's read path will re-tuple before render.
    sparklines =
      site.id
      |> SK.query_sparklines(days, source, top_query_strings)
      |> Map.new(fn {q, pairs} ->
        {q, Enum.map(pairs, fn {b, c} -> [b, c] end)}
      end)

    %{
      "stats" => stats,
      "queries" => queries,
      "pages" => pages,
      "ranking_changes" => ranking_changes,
      "opportunity_queue" => opportunity_queue,
      "new_keywords" => new_keywords,
      "lost_keywords" => lost_keywords,
      "pos_dist" => pos_dist,
      "cannibalization" => cannibalization,
      "daily_trends" => daily_trends,
      "sparklines" => sparklines
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
