defmodule SpectabasWeb.Dashboard.SiteLive do
  use SpectabasWeb, :live_view

  @moduledoc "Main site dashboard — overview stats, timeseries chart, top cards."

  import SpectabasWeb.Dashboard.SegmentComponent
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  alias Spectabas.{Accounts, Sites, Analytics, Segments}
  alias Spectabas.Analytics.AnomalyBadges

  @refresh_interval_ms 60_000

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Spectabas.PubSub, "site:#{site.id}")
        schedule_refresh()
      end

      today = site_today(site)

      {:ok,
       socket
       |> assign(:page_title, site.name)
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:preset, "today")
       |> assign(:date_from, today)
       |> assign(:date_to, today)
       |> assign(:compare, true)
       |> assign(:show_date_picker, false)
       |> assign(:segment, [])
       |> assign(:segment_field, nil)
       |> assign(:filter_options, %{})
       |> assign(:saved_segments, Segments.list_saved_segments(user, site))
       |> assign(:show_save_input, false)
       |> assign(:override_date_range, nil)
       |> assign(:live_visitors, 0)
       |> assign(:stats, empty_overview())
       |> assign(:prev_stats, nil)
       |> assign(:timeseries, [])
       |> assign(:timeseries_json, "{}")
       |> assign(:top_pages, nil)
       |> assign(:top_sources, nil)
       |> assign(:top_regions, nil)
       |> assign(:top_browsers, nil)
       |> assign(:top_os, nil)
       |> assign(:entry_pages, nil)
       |> assign(:locations, [])
       |> assign(:timezones, [])
       |> assign(:intents, nil)
       |> assign(:ecommerce, nil)
       |> assign(:identified_users, 0)
       |> assign(:stats_cache, %{})
       |> assign(:deferred_loaded, false)
       |> assign(:deferred_pending, 0)
       |> assign(:anomaly_categories, %{})
       |> load_critical_stats()
       |> then(fn s ->
         if connected?(s), do: send(self(), :load_deferred)
         s
       end)}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    # Invalidate current range cache entry so refresh fetches fresh data
    key = stats_cache_key(socket)
    socket = update(socket, :stats_cache, &Map.delete(&1, key))
    {:noreply, load_stats(socket)}
  end

  def handle_info(:load_deferred, socket) do
    {:noreply, start_deferred_stats(socket)}
  end

  # Each deferred query sends its result here as it completes. The card
  # updates progressively — no waiting for the slowest query. The
  # stats_cache_key guard drops stale results when the user switches ranges
  # while queries are still in flight.
  def handle_info({:deferred_result, key, value, for_cache_key}, socket) do
    if for_cache_key != stats_cache_key(socket) do
      # User navigated to a different range — discard the late result.
      {:noreply, socket}
    else
      socket = assign(socket, key, value)

      pending = max((socket.assigns[:deferred_pending] || 0) - 1, 0)

      socket =
        socket
        |> assign(:deferred_pending, pending)
        |> maybe_push_location_chart_data(key)

      socket =
        if pending == 0 do
          socket
          |> assign(:deferred_loaded, true)
          # Push map + bar data now that locations/timezones have arrived.
          # Do NOT re-push timeseries — it was already pushed from
          # load_critical_stats, and re-pushing causes Chart.js to
          # re-animate the same data (visible as a flicker/redraw).
          |> push_map_data(socket.assigns[:locations] || [])
          |> push_tz_data(socket.assigns[:timezones] || [])
          |> cache_stats(for_cache_key)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def handle_info({:new_event, _event}, socket) do
    # Don't query ClickHouse on every PubSub message — the 60-second refresh
    # timer handles periodic updates. Just bump the live visitor count by 1
    # as a quick local approximation until next full refresh.
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("preset", %{"range" => range}, socket) do
    today = site_today(socket.assigns.site)

    {from, to} =
      case range do
        "today" -> {today, today}
        "yesterday" -> {Date.add(today, -1), Date.add(today, -1)}
        "7d" -> {Date.add(today, -7), today}
        "30d" -> {Date.add(today, -30), today}
        "90d" -> {Date.add(today, -90), today}
        "ytd" -> {Date.new!(today.year, 1, 1), today}
        "12m" -> {Date.add(today, -365), today}
        # "24h" is special — rolling 24h window, not date-based
        _ -> {Date.add(today, -7), today}
      end

    # For "24h", override with a rolling 24-hour UTC window
    socket =
      if range == "24h" do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        h24_from = DateTime.add(now, -24, :hour)

        socket
        |> assign(:preset, "24h")
        |> assign(:date_from, DateTime.to_date(h24_from))
        |> assign(:date_to, today)
        |> assign(:show_date_picker, false)
        |> assign(:override_date_range, %{from: h24_from, to: now})
        |> load_stats()
      else
        socket
        |> assign(:preset, range)
        |> assign(:date_from, from)
        |> assign(:date_to, to)
        |> assign(:show_date_picker, false)
        |> assign(:override_date_range, nil)
        |> load_stats()
      end

    {:noreply, socket}
  end

  def handle_event("toggle_date_picker", _params, socket) do
    {:noreply, assign(socket, :show_date_picker, !socket.assigns.show_date_picker)}
  end

  def handle_event("custom_range", %{"from" => from_str, "to" => to_str}, socket) do
    with {:ok, from} <- Date.from_iso8601(from_str),
         {:ok, to} <- Date.from_iso8601(to_str) do
      {:noreply,
       socket
       |> assign(:preset, "custom")
       |> assign(:date_from, from)
       |> assign(:date_to, to)
       |> assign(:show_date_picker, false)
       |> load_stats()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("segment_field_changed", params, socket) do
    field = Map.get(params, "field")

    if field do
      dropdown_fields = SpectabasWeb.Dashboard.SegmentComponent.dropdown_fields()

      # Load filter options on first request, then cache in assigns
      socket =
        if Map.get(dropdown_fields, field) && socket.assigns.filter_options == %{} do
          options = Spectabas.Analytics.Segment.filter_options(socket.assigns.site.id)
          assign(socket, :filter_options, options)
        else
          socket
        end

      {:noreply, assign(socket, :segment_field, field)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "update_segment",
        %{"action" => "add", "field" => f, "op" => op, "value" => v},
        socket
      )
      when v != "" do
    filter = %{"field" => f, "op" => op, "value" => v}
    {:noreply, socket |> assign(:segment, socket.assigns.segment ++ [filter]) |> load_stats()}
  end

  def handle_event("update_segment", %{"action" => "remove", "index" => idx}, socket) do
    idx = String.to_integer(idx)
    segment = List.delete_at(socket.assigns.segment, idx)
    {:noreply, socket |> assign(:segment, segment) |> load_stats()}
  end

  def handle_event("update_segment", %{"action" => "clear"}, socket) do
    {:noreply, socket |> assign(:segment, []) |> load_stats()}
  end

  def handle_event("update_segment", %{"action" => "show_save"}, socket) do
    {:noreply, assign(socket, :show_save_input, true)}
  end

  def handle_event("update_segment", %{"action" => "hide_save"}, socket) do
    {:noreply, assign(socket, :show_save_input, false)}
  end

  def handle_event(
        "update_segment",
        %{"action" => "save", "segment_name" => name},
        socket
      )
      when name != "" do
    if !Accounts.can_write?(socket.assigns.current_scope.user) do
      {:noreply, put_flash(socket, :error, "Viewers have read-only access.")}
    else
      %{user: user, site: site, segment: segment} = socket.assigns

      case Segments.save_segment(user, site, name, segment) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:saved_segments, Segments.list_saved_segments(user, site))
           |> assign(:show_save_input, false)}

        _ ->
          {:noreply, assign(socket, :show_save_input, false)}
      end
    end
  end

  def handle_event("update_segment", %{"action" => "load", "segment_id" => id}, socket) do
    %{user: user, site: site} = socket.assigns
    saved = Segments.get_segment!(id, user, site)
    filters = normalize_filters(saved.filters)
    {:noreply, socket |> assign(:segment, filters) |> load_stats()}
  end

  def handle_event("update_segment", %{"action" => "delete_saved", "segment_id" => id}, socket) do
    if !Accounts.can_write?(socket.assigns.current_scope.user) do
      {:noreply, put_flash(socket, :error, "Viewers have read-only access.")}
    else
      %{user: user, site: site} = socket.assigns
      Segments.delete_segment(user, id)

      {:noreply, assign(socket, :saved_segments, Segments.list_saved_segments(user, site))}
    end
  end

  def handle_event("update_segment", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_compare", _params, socket) do
    {:noreply,
     socket
     |> assign(:compare, !socket.assigns.compare)
     |> load_stats()}
  end

  def handle_event("set_chart_metric", %{"metric" => metric}, socket)
      when metric in ["pageviews", "visitors"] do
    {:noreply,
     socket
     |> assign(:chart_metric, metric)
     |> push_chart_data(
       socket.assigns.timeseries,
       socket.assigns[:locations] || [],
       socket.assigns[:timezones] || []
     )}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp date_range_and_opts(socket) do
    %{date_from: from, date_to: to, segment: segment, site: site} = socket.assigns

    # "24h" preset uses a precise rolling window override
    date_range =
      case Map.get(socket.assigns, :override_date_range) do
        %{from: _, to: _} = override ->
          override

        _ ->
          tz = site.timezone || "UTC"
          {from_dt, to_dt} = dates_to_utc_range(from, to, tz)
          %{from: from_dt, to: to_dt}
      end

    {date_range, [segment: segment]}
  end

  # Convert local Date range to UTC DateTime range using site timezone
  defp dates_to_utc_range(from, to, tz) do
    case DateTime.now(tz) do
      {:ok, _} ->
        from_dt = DateTime.new!(from, ~T[00:00:00], tz) |> DateTime.shift_zone!("Etc/UTC")
        # End of day: 23:59:59 in site timezone
        to_dt = DateTime.new!(to, ~T[23:59:59], tz) |> DateTime.shift_zone!("Etc/UTC")
        {from_dt, to_dt}

      _ ->
        # Invalid timezone — fall back to UTC
        {DateTime.new!(from, ~T[00:00:00]), DateTime.new!(to, ~T[23:59:59])}
    end
  end

  @cached_assigns ~w(stats prev_stats timeseries live_visitors top_pages top_sources
                     top_regions top_browsers top_os entry_pages locations timezones
                     intents ecommerce identified_users anomaly_categories)a

  # Full reload — checks cache first, falls back to queries.
  # On cache miss, critical stats load synchronously (fast: stats_fast + rollup)
  # and deferred stats start asynchronously — each card appears as its query
  # completes, so the user never waits for the slowest card before seeing
  # anything. Cache entry is written by handle_info when the last deferred
  # result arrives.
  defp load_stats(socket) do
    key = stats_cache_key(socket)

    case Map.get(socket.assigns.stats_cache, key) do
      nil ->
        socket
        |> reset_deferred_assigns()
        |> load_critical_stats()
        |> start_deferred_stats()

      cached ->
        socket
        |> restore_from_cache(cached)
    end
  end

  # Clear deferred table/card assigns to their "loading" state so cards show a
  # spinner between range changes. Keep locations/timezones from the previous
  # range so the map/bar chart don't briefly go blank — they'll be replaced
  # when the new deferred results arrive.
  defp reset_deferred_assigns(socket) do
    socket
    |> assign(:top_pages, nil)
    |> assign(:top_sources, nil)
    |> assign(:top_regions, nil)
    |> assign(:top_browsers, nil)
    |> assign(:top_os, nil)
    |> assign(:entry_pages, nil)
    |> assign(:intents, nil)
    |> assign(:ecommerce, nil)
    |> assign(:identified_users, 0)
    |> assign(:deferred_loaded, false)
  end

  defp stats_cache_key(socket) do
    {socket.assigns.preset, socket.assigns.date_from, socket.assigns.date_to,
     socket.assigns.segment, socket.assigns.compare}
  end

  defp cache_stats(socket, key) do
    cached = Map.take(socket.assigns, @cached_assigns)
    update(socket, :stats_cache, &Map.put(&1, key, cached))
  end

  defp restore_from_cache(socket, cached) do
    socket
    |> assign(cached)
    |> assign(:deferred_loaded, true)
    |> push_chart_data(
      cached.timeseries,
      cached[:locations] || [],
      cached[:timezones] || []
    )
  end

  # Fast path: overview stats + timeseries (renders above the fold)
  # Runs queries in parallel for 2-3x faster mount.
  defp load_critical_stats(socket) do
    %{site: site, user: user, compare: compare, preset: preset, date_from: from, date_to: to} =
      socket.assigns

    {date_range, seg_opts} = date_range_and_opts(socket)
    period = preset_to_period(preset, from, to)

    # Use pre-aggregated daily_stats for 7d+ ranges (much faster on large tables)
    days_in_range = Date.diff(to, from)

    stats_task =
      Task.async(fn ->
        timed("stats", site.id, days_in_range, fn ->
          fetch_overview(site, user, date_range, seg_opts, days_in_range)
        end)
      end)

    timeseries_task =
      Task.async(fn ->
        timed("timeseries", site.id, days_in_range, fn ->
          # Use daily_rollup-backed path for any multi-day range (7d, 30d, 90d, etc.).
          # Short ranges (Today, 24h) keep hourly granularity via timeseries/4.
          result =
            if days_in_range >= 7 do
              Analytics.timeseries_fast(site, user, date_range, period)
            else
              Analytics.timeseries(site, user, date_range, period)
            end

          case result do
            {:ok, rows} -> rows
            _ -> []
          end
        end)
      end)

    realtime_task =
      Task.async(fn ->
        timed("realtime", site.id, days_in_range, fn ->
          case Analytics.realtime_visitors(site) do
            {:ok, count} -> count
            _ -> 0
          end
        end)
      end)

    prev_task =
      if compare do
        days = Date.diff(to, from)
        tz = site.timezone || "UTC"

        {prev_from, prev_to} =
          dates_to_utc_range(Date.add(from, -(days + 1)), Date.add(from, -1), tz)

        Task.async(fn ->
          timed("prev_stats", site.id, days_in_range, fn ->
            fetch_overview(site, user, %{from: prev_from, to: prev_to}, [])
          end)
        end)
      else
        nil
      end

    # Collect results with safe yields — timeouts degrade gracefully, not crash
    stats = safe_yield(stats_task, empty_overview())
    timeseries = safe_yield(timeseries_task, [])
    live_visitors = safe_yield(realtime_task, 0)
    prev_stats = if prev_task, do: safe_yield(prev_task, nil), else: nil

    socket
    |> assign(:stats, stats)
    |> assign(:prev_stats, prev_stats)
    |> assign(:timeseries, timeseries)
    |> assign(:live_visitors, live_visitors)
    |> assign_new(:chart_metric, fn -> "visitors" end)
    # Build timeseries JSON for the data-chart attribute (race-free initial
    # render). Also push via push_event for updates (metric switch, refresh).
    |> assign(
      :timeseries_json,
      build_timeseries_json(timeseries, socket.assigns[:chart_metric] || "visitors")
    )
    |> push_timeseries_data(timeseries)
  end

  defp build_timeseries_json(timeseries, metric) do
    Jason.encode!(%{
      labels: Enum.map(timeseries, & &1["label"]),
      pageviews: Enum.map(timeseries, &to_num(&1["pageviews"])),
      visitors: Enum.map(timeseries, &to_num(&1["visitors"])),
      metric: metric
    })
  rescue
    _ -> "{}"
  end

  defp push_timeseries_data(socket, timeseries) do
    if Phoenix.LiveView.connected?(socket) do
      push_event(socket, "timeseries-data", %{
        labels: Enum.map(timeseries, & &1["label"]),
        pageviews: Enum.map(timeseries, &to_num(&1["pageviews"])),
        visitors: Enum.map(timeseries, &to_num(&1["visitors"])),
        metric: socket.assigns[:chart_metric] || "visitors"
      })
    else
      socket
    end
  end

  # Slow path: all the data cards, map, timezones.
  # Spawns each query as an unlinked Task that sends its result back via
  # {:deferred_result, assign_key, value, cache_key} — the LiveView renders
  # each card as soon as its query completes, instead of waiting for the
  # slowest one. cache_key lets handle_info drop stale results when the user
  # changes ranges while queries are still in flight.
  defp start_deferred_stats(socket) do
    %{site: site, user: user} = socket.assigns
    {date_range, seg_opts} = date_range_and_opts(socket)
    cache_key = stats_cache_key(socket)
    lv_pid = self()

    days_in_range = Date.diff(socket.assigns.date_to, socket.assigns.date_from)

    # For segmented queries we must hit raw events. Unsegmented queries
    # can use the _fast rollup variants which are orders of magnitude cheaper.
    use_fast? = Keyword.get(seg_opts, :segment, []) == []

    top_pages_fn =
      if use_fast?,
        do: fn -> Analytics.top_pages_fast(site, user, date_range) end,
        else: fn -> Analytics.top_pages(site, user, date_range, seg_opts) end

    top_sources_fn =
      if use_fast?,
        do: fn -> Analytics.top_sources_fast(site, user, date_range) end,
        else: fn -> Analytics.top_sources(site, user, date_range) end

    top_regions_fn =
      if use_fast?,
        do: fn -> Analytics.top_regions_fast(site, user, date_range) end,
        else: fn -> Analytics.top_regions(site, user, date_range) end

    top_browsers_fn =
      if use_fast?,
        do: fn -> Analytics.top_browsers_fast(site, user, date_range) end,
        else: fn -> Analytics.top_browsers(site, user, date_range) end

    top_os_fn =
      if use_fast?,
        do: fn -> Analytics.top_os_fast(site, user, date_range) end,
        else: fn -> Analytics.top_os(site, user, date_range) end

    locations_fn =
      if use_fast?,
        do: fn -> Analytics.visitor_locations_fast(site, user, date_range) end,
        else: fn -> Analytics.visitor_locations(site, user, date_range) end

    timezones_fn =
      if use_fast?,
        do: fn -> Analytics.timezone_distribution_fast(site, user, date_range) end,
        else: fn -> Analytics.timezone_distribution(site, user, date_range) end

    # List of {assign_key, fallback, fn/0} for each deferred query.
    jobs = [
      {:top_pages, [],
       fn ->
         timed("top_pages", site.id, days_in_range, fn ->
           safe_query(top_pages_fn) |> Enum.take(5)
         end)
       end},
      {:top_sources, [],
       fn ->
         timed("top_sources", site.id, days_in_range, fn ->
           safe_query(top_sources_fn) |> Enum.take(5)
         end)
       end},
      {:top_regions, [],
       fn ->
         timed("top_regions", site.id, days_in_range, fn ->
           safe_query(top_regions_fn) |> Enum.take(5)
         end)
       end},
      {:top_browsers, [],
       fn ->
         timed("top_browsers", site.id, days_in_range, fn ->
           safe_query(top_browsers_fn) |> Enum.take(5)
         end)
       end},
      {:top_os, [],
       fn ->
         timed("top_os", site.id, days_in_range, fn ->
           safe_query(top_os_fn) |> Enum.take(5)
         end)
       end},
      {:entry_pages, [],
       fn ->
         timed("entry_pages", site.id, days_in_range, fn ->
           safe_query(fn -> Analytics.entry_pages(site, user, date_range) end) |> Enum.take(5)
         end)
       end},
      {:locations, [],
       fn ->
         timed("locations", site.id, days_in_range, fn ->
           safe_query(locations_fn) |> Enum.take(50)
         end)
       end},
      {:timezones, [],
       fn ->
         timed("timezones", site.id, days_in_range, fn ->
           safe_query(timezones_fn) |> Enum.take(5)
         end)
       end},
      {:intents, [],
       fn ->
         timed("intents", site.id, days_in_range, fn ->
           safe_query(fn -> Analytics.intent_breakdown(site, user, date_range) end)
           |> Enum.take(10)
         end)
       end},
      {:identified_users, 0,
       fn ->
         timed("identified_users", site.id, days_in_range, fn ->
           case Analytics.identified_visitors_count(site, user, date_range) do
             {:ok, count} -> count
             _ -> 0
           end
         end)
       end}
    ]

    jobs =
      if site.ecommerce_enabled do
        jobs ++
          [
            {:ecommerce, nil,
             fn ->
               timed("ecommerce", site.id, days_in_range, fn ->
                 case Analytics.ecommerce_stats(site, user, date_range) do
                   {:ok, data} -> data
                   _ -> nil
                 end
               end)
             end}
          ]
      else
        jobs
      end

    # Anomaly badges — only compute once per dashboard load (not cached per date range)
    jobs =
      jobs ++
        [
          {:anomaly_categories, %{},
           fn ->
             timed("anomaly_badges", site.id, days_in_range, fn ->
               AnomalyBadges.compute(site, user)
             end)
           end}
        ]

    # Spawn each job. Results are sent back as {:deferred_result, key, value, cache_key}.
    # Unlinked Task.start so a crash doesn't take the LiveView down.
    Enum.each(jobs, fn {key, fallback, fun} ->
      Task.start(fn ->
        result =
          try do
            fun.()
          rescue
            e ->
              require Logger

              Logger.error(
                "[Dashboard] #{key} crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
              )

              fallback
          end

        send(lv_pid, {:deferred_result, key, result, cache_key})
      end)
    end)

    socket
    |> assign(:deferred_pending, length(jobs))
    |> assign(:deferred_loaded, false)
  end

  defp fetch_overview(site, user, date_range, opts, _days_in_range \\ 0) do
    # Always use the fast variant — it's a single raw-events scan with uniq()
    # (HyperLogLog) instead of the slow session-grouped uniqExact subquery.
    # Falls back to regular overview_stats only when segments are active
    # (handled inside overview_stats_fast itself).
    result = Analytics.overview_stats_fast(site, user, date_range, opts)

    case result do
      {:ok, s} ->
        %{
          pageviews: to_num(s["pageviews"]),
          unique_visitors: to_num(s["unique_visitors"]),
          sessions: to_num(s["total_sessions"]),
          bounce_rate: to_float(s["bounce_rate"]),
          avg_duration: to_num(s["avg_duration"])
        }

      _ ->
        %{pageviews: 0, unique_visitors: 0, sessions: 0, bounce_rate: 0.0, avg_duration: 0}
    end
  end

  defp push_chart_data(socket, timeseries, locations, timezones) do
    if Phoenix.LiveView.connected?(socket) do
      socket
      |> push_event("timeseries-data", %{
        labels: Enum.map(timeseries, & &1["label"]),
        pageviews: Enum.map(timeseries, &to_num(&1["pageviews"])),
        visitors: Enum.map(timeseries, &to_num(&1["visitors"])),
        metric: socket.assigns[:chart_metric] || "visitors"
      })
      |> push_map_data(locations)
      |> push_tz_data(timezones)
    else
      socket
    end
  end

  defp push_map_data(socket, locations) do
    push_event(socket, "map-data", %{
      points:
        Enum.map(locations, fn loc ->
          %{
            lat: to_float(loc["ip_lat"]),
            lon: to_float(loc["ip_lon"]),
            visitors: to_num(loc["visitors"]),
            label: location_label(loc)
          }
        end)
    })
  end

  defp push_tz_data(socket, timezones) do
    push_event(socket, "bar-data", %{
      labels: Enum.map(timezones, &short_tz(&1["timezone"])),
      values: Enum.map(timezones, &to_num(&1["visitors"]))
    })
  end

  # When a deferred result arrives that feeds a chart, push just that chart's data.
  defp maybe_push_location_chart_data(socket, :locations) do
    if Phoenix.LiveView.connected?(socket) do
      push_map_data(socket, socket.assigns.locations)
    else
      socket
    end
  end

  defp maybe_push_location_chart_data(socket, :timezones) do
    if Phoenix.LiveView.connected?(socket) do
      push_tz_data(socket, socket.assigns.timezones)
    else
      socket
    end
  end

  defp maybe_push_location_chart_data(socket, _key), do: socket

  defp preset_to_period("today", _, _), do: :day
  defp preset_to_period("yesterday", _, _), do: :day
  defp preset_to_period("24h", _, _), do: :day
  defp preset_to_period("7d", _, _), do: :week
  defp preset_to_period("30d", _, _), do: :month

  defp preset_to_period(_, from, to) do
    days = Date.diff(to, from)

    cond do
      days <= 2 -> :day
      days <= 31 -> :week
      true -> :month
    end
  end

  # Normalize saved segment filters from Postgres JSON (may have atom or string keys)
  defp normalize_filters(filters) when is_list(filters) do
    Enum.map(filters, fn f ->
      %{
        "field" => Map.get(f, "field") || Map.get(f, :field, ""),
        "op" => Map.get(f, "op") || Map.get(f, :op, "is"),
        "value" => Map.get(f, "value") || Map.get(f, :value, "")
      }
    end)
  end

  defp normalize_filters(_), do: []

  # Yield a Task result with fallback on timeout — never crashes the LiveView
  defp safe_yield(task, fallback) do
    case Task.yield(task, 10_000) || Task.shutdown(task) do
      {:ok, result} ->
        result

      _ ->
        require Logger
        Logger.warning("[Dashboard] Query task timed out or crashed")
        fallback
    end
  end

  defp empty_overview do
    %{
      pageviews: 0,
      unique_visitors: 0,
      sessions: 0,
      bounce_rate: 0.0,
      avg_duration: 0
    }
  end

  # Times a dashboard query and logs slow ones so we can see in AppSignal
  # exactly where the 7d/30d delay is coming from. Threshold 500ms.
  defp timed(name, site_id, days, fun) do
    t0 = System.monotonic_time(:millisecond)
    result = fun.()
    ms = System.monotonic_time(:millisecond) - t0

    if ms >= 500 do
      require Logger

      Logger.notice("[Dashboard:slow] #{name} site=#{site_id} days=#{days} took=#{ms}ms")
    end

    result
  end

  defp preset_label("today"), do: "Today"
  defp preset_label("yesterday"), do: "Yesterday"
  defp preset_label("24h"), do: "24h"
  defp preset_label("7d"), do: "7 days"
  defp preset_label("30d"), do: "30 days"
  defp preset_label("90d"), do: "90 days"
  defp preset_label("12m"), do: "12 months"
  defp preset_label(_), do: "period"

  defp site_today(site) do
    tz = site.timezone || "UTC"

    case DateTime.now(tz) do
      {:ok, local_now} -> DateTime.to_date(local_now)
      _ -> Date.utc_today()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      active="overview"
      live_visitors={@live_visitors}
      page_title="Dashboard"
      page_description="Overview of your site's traffic, visitors, and engagement metrics."
      anomaly_categories={@anomaly_categories}
    >
      <div class="max-w-7xl mx-auto px-3 sm:px-6 lg:px-8 py-4 sm:py-6">
        <%!-- Time Period + Compare --%>
        <div class="flex flex-wrap items-center gap-2 mb-4">
          <div class="flex gap-1 bg-gray-100 rounded-lg p-1">
            <button
              :for={
                {id, label} <- [
                  {"today", "Today"},
                  {"yesterday", "Yesterday"},
                  {"24h", "24h"},
                  {"7d", "7d"},
                  {"30d", "30d"},
                  {"90d", "90d"},
                  {"12m", "12m"}
                ]
              }
              phx-click="preset"
              phx-value-range={id}
              class={[
                "px-2 py-1 text-xs sm:text-sm font-medium rounded-md",
                if(@preset == id,
                  do: "bg-white shadow text-gray-900",
                  else: "text-gray-600 hover:text-gray-900"
                )
              ]}
            >
              {label}
            </button>
          </div>
          <span class="text-xs text-gray-500 hidden sm:inline">
            {Calendar.strftime(@date_from, "%b %d")} - {Calendar.strftime(@date_to, "%b %d, %Y")}
          </span>
          <button
            phx-click="toggle_compare"
            class={[
              "px-2 py-1 text-xs font-medium rounded-md",
              if(@compare,
                do: "bg-indigo-50 text-indigo-700 border border-indigo-200",
                else: "text-gray-500 border border-gray-200 hover:bg-gray-50"
              )
            ]}
          >
            Compare
          </button>
        </div>

        <%!-- Segment Filter --%>
        <.segment_filter
          segment={@segment}
          saved_segments={@saved_segments}
          show_save_input={@show_save_input}
          filter_options={@filter_options}
          segment_field={@segment_field}
        />

        <%!-- Stat Cards with Comparison --%>
        <% period_label = preset_label(@preset) %>
        <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
          <.stat_card
            label="Pageviews"
            value={format_number(@stats.pageviews)}
            prev={@prev_stats && @prev_stats.pageviews}
            current={@stats.pageviews}
            period={period_label}
          />
          <.stat_card
            label="Unique Visitors"
            value={format_number(@stats.unique_visitors)}
            prev={@prev_stats && @prev_stats.unique_visitors}
            current={@stats.unique_visitors}
            period={period_label}
          />
          <.stat_card
            label="Sessions"
            value={format_number(@stats.sessions)}
            prev={@prev_stats && @prev_stats.sessions}
            current={@stats.sessions}
            period={period_label}
          />
          <.stat_card
            label="Bounce Rate"
            value={"#{@stats.bounce_rate}%"}
            prev={@prev_stats && @prev_stats.bounce_rate}
            current={@stats.bounce_rate}
            invert={true}
            period={period_label}
          />
          <.stat_card
            label="Avg Duration"
            value={format_duration(@stats.avg_duration)}
            prev={@prev_stats && @prev_stats.avg_duration}
            current={@stats.avg_duration}
            period={period_label}
          />
        </div>

        <%!-- Identified Users + Ecommerce Row --%>
        <div
          :if={@identified_users > 0 || @ecommerce}
          class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6"
        >
          <div :if={@identified_users > 0} class="bg-white rounded-lg shadow p-3 sm:p-4">
            <dt class="text-xs sm:text-sm font-medium text-gray-500 truncate">Identified Users</dt>
            <dd class="mt-1 text-xl sm:text-2xl font-bold text-indigo-600">
              {format_number(@identified_users)}
            </dd>
            <dd class="mt-1 text-xs text-gray-500">
              {if @stats.unique_visitors > 0,
                do:
                  "#{Float.round(@identified_users / @stats.unique_visitors * 100, 1)}% of visitors",
                else: "of visitors"}
            </dd>
          </div>
          <div :if={@ecommerce} class="bg-white rounded-lg shadow p-3 sm:p-4">
            <dt class="text-xs sm:text-sm font-medium text-gray-500 truncate">Revenue</dt>
            <dd class="mt-1 text-xl sm:text-2xl font-bold text-green-600">
              {Spectabas.Currency.format(@ecommerce["total_revenue"], @site.currency)}
            </dd>
          </div>
          <div :if={@ecommerce} class="bg-white rounded-lg shadow p-3 sm:p-4">
            <dt class="text-xs sm:text-sm font-medium text-gray-500 truncate">Orders</dt>
            <dd class="mt-1 text-xl sm:text-2xl font-bold text-gray-900">
              {format_number(to_num(@ecommerce["total_orders"]))}
            </dd>
          </div>
          <div :if={@ecommerce} class="bg-white rounded-lg shadow p-3 sm:p-4">
            <dt class="text-xs sm:text-sm font-medium text-gray-500 truncate">Avg Order</dt>
            <dd class="mt-1 text-xl sm:text-2xl font-bold text-gray-900">
              {Spectabas.Currency.format(@ecommerce["avg_order_value"], @site.currency)}
            </dd>
            <dd class="mt-1">
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/ecommerce"}
                class="text-xs text-indigo-600 hover:text-indigo-800"
              >
                View details &rarr;
              </.link>
            </dd>
          </div>
        </div>

        <%!-- Time-series Chart --%>
        <div class="bg-white rounded-lg shadow p-5 mb-6">
          <div class="flex items-center justify-end gap-1 mb-3">
            <button
              phx-click="set_chart_metric"
              phx-value-metric="pageviews"
              class={[
                "px-3 py-1 text-xs font-medium rounded-lg transition-colors",
                if(@chart_metric == "pageviews",
                  do: "bg-indigo-600 text-white",
                  else: "text-gray-600 hover:bg-gray-100"
                )
              ]}
            >
              Pageviews
            </button>
            <button
              phx-click="set_chart_metric"
              phx-value-metric="visitors"
              class={[
                "px-3 py-1 text-xs font-medium rounded-lg transition-colors",
                if(@chart_metric == "visitors",
                  do: "bg-emerald-600 text-white",
                  else: "text-gray-600 hover:bg-gray-100"
                )
              ]}
            >
              Visitors
            </button>
          </div>
          <div
            id="timeseries-hook"
            phx-hook="TimeseriesChart"
            phx-update="ignore"
            data-chart={@timeseries_json}
            class="h-48 sm:h-[280px] relative"
          >
            <canvas></canvas>
          </div>
        </div>

        <%!-- Data Cards Grid --%>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          <.data_card
            title="Top Pages"
            link={~p"/dashboard/sites/#{@site.id}/pages"}
            loading={is_nil(@top_pages)}
            empty={@top_pages == []}
          >
            <div :for={row <- @top_pages || []} class="flex items-center justify-between py-2">
              <span class="text-sm text-gray-800 truncate mr-4" title={row["url_path"]}>
                {row["url_path"]}
              </span>
              <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
                {format_number(row["pageviews"])}
              </span>
            </div>
          </.data_card>

          <.data_card
            title="Top Sources"
            link={~p"/dashboard/sites/#{@site.id}/sources"}
            loading={is_nil(@top_sources)}
            empty={@top_sources == []}
          >
            <div :for={row <- @top_sources || []} class="flex items-center justify-between py-2">
              <span class="text-sm text-gray-800 truncate mr-4">
                {row["referrer_domain"] || "Direct"}
              </span>
              <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
                {format_number(row["pageviews"])}
              </span>
            </div>
          </.data_card>

          <.data_card
            title="Top States"
            link={~p"/dashboard/sites/#{@site.id}/geo"}
            loading={is_nil(@top_regions)}
            empty={@top_regions == []}
          >
            <div :for={row <- @top_regions || []} class="flex items-center justify-between py-2">
              <span class="text-sm text-gray-800 truncate mr-4">
                {region_display(row)}
              </span>
              <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
                {format_number(row["unique_visitors"])}
              </span>
            </div>
          </.data_card>

          <.data_card
            title="Top Browsers"
            link={~p"/dashboard/sites/#{@site.id}/devices"}
            loading={is_nil(@top_browsers)}
            empty={@top_browsers == []}
          >
            <div :for={row <- @top_browsers || []} class="flex items-center justify-between py-2">
              <span class="text-sm text-gray-800 truncate mr-4">
                {row["name"] || "Unknown"}
              </span>
              <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
                {format_number(row["unique_visitors"])}
              </span>
            </div>
          </.data_card>

          <.data_card
            title="Top OS"
            link={~p"/dashboard/sites/#{@site.id}/devices"}
            loading={is_nil(@top_os)}
            empty={@top_os == []}
          >
            <div :for={row <- @top_os || []} class="flex items-center justify-between py-2">
              <span class="text-sm text-gray-800 truncate mr-4">
                {row["name"] || "Unknown"}
              </span>
              <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
                {format_number(row["unique_visitors"])}
              </span>
            </div>
          </.data_card>

          <.data_card
            title="Entry Pages"
            link={~p"/dashboard/sites/#{@site.id}/entry-exit"}
            loading={is_nil(@entry_pages)}
            empty={@entry_pages == []}
          >
            <div :for={row <- @entry_pages || []} class="flex items-center justify-between py-2">
              <span class="text-sm text-gray-800 truncate mr-4 font-mono" title={row["url_path"]}>
                {row["url_path"]}
              </span>
              <span class="text-sm font-medium text-gray-600 tabular-nums whitespace-nowrap">
                {format_number(row["entries"])}
              </span>
            </div>
          </.data_card>

          <.data_card
            title="Realtime"
            link={~p"/dashboard/sites/#{@site.id}/realtime"}
            empty={false}
          >
            <div class="flex flex-col items-center justify-center py-4">
              <div class="text-4xl font-bold text-gray-900">{format_number(@live_visitors)}</div>
              <div class="text-sm text-gray-500 mt-1">active visitors</div>
            </div>
          </.data_card>
        </div>

        <%!-- Visitor Intent --%>
        <div :if={@intents && @intents != []} class="bg-white rounded-lg shadow overflow-hidden mt-6">
          <div class="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
            <h3 class="font-semibold text-gray-900">Visitor Intent</h3>
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/visitor-log"}
              class="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
            >
              View all &rarr;
            </.link>
          </div>
          <div class="px-5 py-4">
            <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-7 gap-3">
              <.link
                :for={intent <- @intents}
                navigate={
                  ~p"/dashboard/sites/#{@site.id}/visitor-log?filter_field=visitor_intent&filter_value=#{intent["intent"]}"
                }
                class="text-center group hover:bg-gray-50 rounded-lg p-2 transition-colors"
              >
                <div class={"inline-flex items-center justify-center w-8 h-8 sm:w-10 sm:h-10 rounded-full mb-1 sm:mb-1.5 " <> intent_color(intent["intent"])}>
                  {raw(intent_icon(intent["intent"]))}
                </div>
                <div class="text-base sm:text-lg font-bold text-gray-900 group-hover:text-indigo-600">
                  {format_number(to_num(intent["visitors"]))}
                </div>
                <div class="text-xs text-gray-500 capitalize">{intent["intent"]}</div>
              </.link>
            </div>
          </div>
        </div>

        <%!-- Visitor Map --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mt-6">
          <div class="bg-white rounded-lg shadow p-5">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-sm font-medium text-gray-500">Visitor Map</h3>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/map"}
                class="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
              >
                View details &rarr;
              </.link>
            </div>
            <div
              id="map-hook"
              phx-hook="BubbleMap"
              phx-update="ignore"
            >
              <div class="h-48 sm:h-[300px] relative">
                <canvas></canvas>
              </div>
            </div>
          </div>

          <%!-- Top Cities --%>
          <div class="bg-white rounded-lg shadow p-5">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-sm font-medium text-gray-500">Top Cities</h3>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/geo"}
                class="text-xs text-indigo-600 hover:text-indigo-800 font-medium"
              >
                View all &rarr;
              </.link>
            </div>
            <div :if={@locations == []} class="py-4 text-center text-sm text-gray-500">
              No location data yet
            </div>
            <div :if={@locations != []} class="divide-y divide-gray-50">
              <div
                :for={loc <- Enum.take(@locations, 8)}
                class="flex items-center justify-between py-2"
              >
                <span class="text-sm text-gray-800 truncate mr-4">
                  {location_label(loc)}
                </span>
                <span class="text-sm font-medium text-gray-600 tabular-nums">
                  {format_number(to_num(loc["visitors"]))}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  # -- Components --

  defp stat_card(assigns) do
    assigns =
      assigns
      |> Map.put_new(:prev, nil)
      |> Map.put_new(:current, nil)
      |> Map.put_new(:invert, false)
      |> Map.put_new(:period, "")

    ~H"""
    <div class="bg-white rounded-lg shadow p-3 sm:p-4">
      <dt class="text-xs sm:text-sm font-medium text-gray-500 truncate">{@label}</dt>
      <dd class="mt-1 text-xl sm:text-2xl font-bold text-gray-900">{@value}</dd>
      <dd :if={@prev != nil} class="mt-1">
        <% delta = compute_delta(@current, @prev, @invert) %>
        <span class={[
          "text-xs font-medium",
          if(delta.direction == :up, do: "text-green-600", else: ""),
          if(delta.direction == :down, do: "text-red-600", else: ""),
          if(delta.direction == :flat, do: "text-gray-500", else: "")
        ]}>
          {delta.label}
        </span>
        <span class="text-xs text-gray-500 ml-1">vs prev {@period}</span>
      </dd>
    </div>
    """
  end

  defp data_card(assigns) do
    assigns = assign_new(assigns, :loading, fn -> false end)

    ~H"""
    <div class="bg-white rounded-lg shadow overflow-x-auto">
      <div class="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
        <h3 class="font-semibold text-gray-900">{@title}</h3>
        <.link navigate={@link} class="text-xs text-indigo-600 hover:text-indigo-800 font-medium">
          View all &rarr;
        </.link>
      </div>
      <div class="px-5 py-2 divide-y divide-gray-50">
        <div :if={@loading} class="py-6 text-center">
          <div class="inline-block h-5 w-5 animate-spin rounded-full border-2 border-indigo-600 border-r-transparent">
          </div>
        </div>
        <div :if={!@loading && @empty} class="py-6 text-center text-sm text-gray-500">
          No data yet
        </div>
        <div :if={!@loading}>{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp compute_delta(current, prev, invert) when is_number(current) and is_number(prev) do
    if prev == 0 do
      if current > 0,
        do: %{label: "new", direction: :flat},
        else: %{label: "—", direction: :flat}
    else
      pct = Float.round((current - prev) / prev * 100, 1)

      direction =
        cond do
          pct > 0 -> if(invert, do: :down, else: :up)
          pct < 0 -> if(invert, do: :up, else: :down)
          true -> :flat
        end

      sign = if pct > 0, do: "+", else: ""
      %{label: "#{sign}#{pct}%", direction: direction}
    end
  end

  defp compute_delta(_, _, _), do: %{label: "", direction: :flat}

  defp short_tz(tz) when is_binary(tz) do
    case String.split(tz, "/") do
      [_, city | _] -> String.replace(city, "_", " ")
      _ -> tz
    end
  end

  defp short_tz(_), do: "Unknown"

  defp intent_color("buying"), do: "bg-green-100 text-green-600"
  defp intent_color("engaging"), do: "bg-emerald-100 text-emerald-600"
  defp intent_color("researching"), do: "bg-blue-100 text-blue-600"
  defp intent_color("comparing"), do: "bg-purple-100 text-purple-600"
  defp intent_color("support"), do: "bg-yellow-100 text-yellow-600"
  defp intent_color("returning"), do: "bg-indigo-100 text-indigo-600"
  defp intent_color("browsing"), do: "bg-gray-100 text-gray-500"
  defp intent_color("bot"), do: "bg-red-100 text-red-500"
  defp intent_color(_), do: "bg-gray-100 text-gray-500"

  # FontAwesome free SVG icons (16x16 viewBox)
  @intent_icons %{
    # shopping-cart
    "buying" =>
      ~s(<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 576 512"><path d="M0 24C0 10.7 10.7 0 24 0H69.5c22 0 41.5 12.8 50.6 32h411c26.3 0 45.5 25 38.6 50.4l-41 152.3c-8.5 31.4-37 53.3-69.5 53.3H170.7l5.4 28.5c2.2 11.3 12.1 19.5 23.6 19.5H488c13.3 0 24 10.7 24 24s-10.7 24-24 24H199.7c-34.6 0-64.3-24.6-70.7-58.5L77.4 54.5c-.7-3.8-4-6.5-7.9-6.5H24C10.7 48 0 37.3 0 24zM128 464a48 48 0 1 1 96 0 48 48 0 1 1-96 0zm336-48a48 48 0 1 1 0 96 48 48 0 1 1 0-96z"/></svg>),
    # magnifying-glass
    "researching" =>
      ~s(<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 512 512"><path d="M416 208c0 45.9-14.9 88.3-40 122.7L502.6 457.4c12.5 12.5 12.5 32.8 0 45.3s-32.8 12.5-45.3 0L330.7 376c-34.4 25.2-76.8 40-122.7 40C93.1 416 0 322.9 0 208S93.1 0 208 0S416 93.1 416 208zM208 352a144 144 0 1 0 0-288 144 144 0 1 0 0 288z"/></svg>),
    # scale-balanced
    "comparing" =>
      ~s(<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 640 512"><path d="M384 32H512c17.7 0 32 14.3 32 32s-14.3 32-32 32H398.4c-5.2 25.8-22.9 47.1-46.4 57.3V448H512c17.7 0 32 14.3 32 32s-14.3 32-32 32H128c-17.7 0-32-14.3-32-32s14.3-32 32-32H288V153.3c-23.5-10.3-41.2-31.6-46.4-57.3H128c-17.7 0-32-14.3-32-32s14.3-32 32-32H256c14.6-19.4 37.8-32 64-32s49.4 12.6 64 32z"/></svg>),
    # life-ring
    "support" =>
      ~s(<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 512 512"><path d="M256 512A256 256 0 1 0 256 0a256 256 0 1 0 0 512zm0-160a96 96 0 1 1 0-192 96 96 0 1 1 0 192z"/></svg>),
    # rotate-left
    "returning" =>
      ~s(<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 512 512"><path d="M125.7 160H176c17.7 0 32 14.3 32 32s-14.3 32-32 32H48c-17.7 0-32-14.3-32-32V64c0-17.7 14.3-32 32-32s32 14.3 32 32v51.2L97.6 97.6c87.5-87.5 229.3-87.5 316.8 0s87.5 229.3 0 316.8s-229.3 87.5-316.8 0c-12.5-12.5-12.5-32.8 0-45.3s32.8-12.5 45.3 0c62.5 62.5 163.8 62.5 226.3 0s62.5-163.8 0-226.3s-163.8-62.5-226.3 0L125.7 160z"/></svg>),
    # eye
    "browsing" =>
      ~s(<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 576 512"><path d="M288 32c-80.8 0-145.5 36.8-192.6 80.6C48.6 156 17.3 208 2.5 243.7c-3.3 7.9-3.3 16.7 0 24.6C17.3 304 48.6 356 95.4 399.4C142.5 443.2 207.2 480 288 480s145.5-36.8 192.6-80.6c46.8-43.5 78.1-95.4 93-131.1c3.3-7.9 3.3-16.7 0-24.6c-14.9-35.7-46.2-87.7-93-131.1C433.5 68.8 368.8 32 288 32zM144 256a144 144 0 1 1 288 0 144 144 0 1 1-288 0zm144-64a64 64 0 1 0 0 128 64 64 0 1 0 0-128z"/></svg>),
    # robot
    "bot" =>
      ~s(<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 640 512"><path d="M320 0c17.7 0 32 14.3 32 32V96H472c39.8 0 72 32.2 72 72V440c0 39.8-32.2 72-72 72H168c-39.8 0-72-32.2-72-72V168c0-39.8 32.2-72 72-72H288V32c0-17.7 14.3-32 32-32zM208 384c-8.8 0-16 7.2-16 16s7.2 16 16 16h32c8.8 0 16-7.2 16-16s-7.2-16-16-16H208zm96 0c-8.8 0-16 7.2-16 16s7.2 16 16 16h32c8.8 0 16-7.2 16-16s-7.2-16-16-16H304zm96 0c-8.8 0-16 7.2-16 16s7.2 16 16 16h32c8.8 0 16-7.2 16-16s-7.2-16-16-16H400zM264 256a40 40 0 1 0-80 0 40 40 0 1 0 80 0zm152-40a40 40 0 1 0 0 80 40 40 0 1 0 0-80z"/></svg>)
  }

  defp intent_icon(intent), do: Map.get(@intent_icons, intent, "")

  defp location_label(loc) do
    city = loc["ip_city"] || ""
    region = loc["ip_region_name"] || ""
    country = loc["ip_country"] || ""
    [city, region, country] |> Enum.reject(&(&1 == "")) |> Enum.join(", ")
  end

  defp region_display(row) do
    region = row["ip_region_name"] || ""
    country = row["ip_country"] || ""

    cond do
      region != "" && country != "" -> "#{region}, #{country}"
      region != "" -> region
      true -> "Unknown"
    end
  end
end
