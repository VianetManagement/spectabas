defmodule Spectabas.Workers.DailyRollupIntegrationTest do
  @moduledoc """
  End-to-end test: insert synthetic events into ClickHouse, run DailyRollup,
  and assert rollup aggregates match a direct raw-events query.

  Excluded from the default test run. To run:

      mix test --only integration

  Requires a working ClickHouse connection (same env as dev). Uses synthetic
  site_id 999_999 and cleans up on exit.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Spectabas.ClickHouse
  alias Spectabas.Workers.DailyRollup

  @site_id 999_999
  @test_date "2026-03-15"

  setup do
    if !clickhouse_reachable?() do
      # Fail fast with a readable message if someone runs --only integration
      # without a CH available.
      flunk("ClickHouse not reachable — integration tests require a running ClickHouse")
    end

    cleanup()
    on_exit(&cleanup/0)
    :ok
  end

  test "rollup aggregates match raw-events aggregates for the same day" do
    # 5 visitors × 3 pageviews = 15 pageviews, 5 unique visitors.
    # Plus some non-pageview noise that must NOT inflate visitor counts.
    events =
      for v <- 1..5, _p <- 1..3 do
        event_row(v, "s#{v}", "pageview", @test_date)
      end ++
        [
          # A duration event from visitor 99 (no pageview from them) — must NOT count
          event_row(99, "s99", "duration", @test_date),
          # A RUM custom event from visitor 88 — must NOT count
          custom_row(88, "s88", "_rum", @test_date),
          # A bot pageview — must NOT count (ip_is_bot=1)
          bot_row(77, "s77", @test_date)
        ]

    assert :ok = ClickHouse.insert("events", events)
    # Force merges so toDate(timestamp) sees the rows immediately
    ClickHouse.execute("OPTIMIZE TABLE events")

    # Run the rollup for this specific date
    assert :ok = DailyRollup.perform(%Oban.Job{args: %{"date" => @test_date}})

    # Query rollup (what timeseries_fast uses)
    rollup_row =
      query_one("""
      SELECT
        countIfMerge(pv_state) AS pv,
        uniqExactIfMerge(vis_state) AS vis,
        uniqExactIfMerge(sess_state) AS sess
      FROM daily_rollup
      WHERE site_id = #{@site_id} AND date = '#{@test_date}'
      """)

    # Query raw events (what overview_stats + fixed timeseries use)
    raw_row =
      query_one("""
      SELECT
        countIf(event_type = 'pageview' AND ip_is_bot = 0) AS pv,
        uniqExactIf(visitor_id, event_type = 'pageview' AND ip_is_bot = 0) AS vis,
        uniqExactIf(session_id, event_type = 'pageview' AND ip_is_bot = 0) AS sess
      FROM events
      WHERE site_id = #{@site_id} AND toDate(timestamp) = '#{@test_date}'
      """)

    assert to_int(rollup_row["pv"]) == 15
    assert to_int(rollup_row["vis"]) == 5
    assert to_int(rollup_row["sess"]) == 5

    assert to_int(rollup_row["pv"]) == to_int(raw_row["pv"])
    assert to_int(rollup_row["vis"]) == to_int(raw_row["vis"])
    assert to_int(rollup_row["sess"]) == to_int(raw_row["sess"])
  end

  test "rerunning the same date is idempotent (no double-count)" do
    events = for v <- 1..3, _ <- 1..2, do: event_row(v, "s#{v}", "pageview", @test_date)
    assert :ok = ClickHouse.insert("events", events)
    ClickHouse.execute("OPTIMIZE TABLE events")

    # Run twice
    assert :ok = DailyRollup.perform(%Oban.Job{args: %{"date" => @test_date}})
    assert :ok = DailyRollup.perform(%Oban.Job{args: %{"date" => @test_date}})

    row =
      query_one("""
      SELECT countIfMerge(pv_state) AS pv, uniqExactIfMerge(vis_state) AS vis
      FROM daily_rollup
      WHERE site_id = #{@site_id} AND date = '#{@test_date}'
      """)

    # 3 visitors × 2 pageviews = 6. Second run must not double it.
    assert to_int(row["pv"]) == 6
    assert to_int(row["vis"]) == 3
  end

  # --- helpers ---

  defp event_row(visitor_n, session_id, event_type, date) do
    %{
      site_id: @site_id,
      visitor_id: "v#{visitor_n}",
      session_id: session_id,
      event_type: event_type,
      timestamp: "#{date} 12:00:00",
      ip_is_bot: 0
    }
  end

  defp custom_row(visitor_n, session_id, event_name, date) do
    %{
      site_id: @site_id,
      visitor_id: "v#{visitor_n}",
      session_id: session_id,
      event_type: "custom",
      event_name: event_name,
      timestamp: "#{date} 12:00:00",
      ip_is_bot: 0
    }
  end

  defp bot_row(visitor_n, session_id, date) do
    %{
      site_id: @site_id,
      visitor_id: "v#{visitor_n}",
      session_id: session_id,
      event_type: "pageview",
      timestamp: "#{date} 12:00:00",
      ip_is_bot: 1
    }
  end

  defp cleanup do
    for table <-
          ~w(events daily_rollup daily_page_rollup daily_source_rollup daily_geo_rollup daily_device_rollup) do
      ClickHouse.execute(
        "ALTER TABLE #{table} DELETE WHERE site_id = #{@site_id} SETTINGS mutations_sync = 2"
      )
    end

    :ok
  end

  defp clickhouse_reachable? do
    case ClickHouse.query("SELECT 1 AS ok") do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp query_one(sql) do
    case ClickHouse.query(sql) do
      {:ok, [row]} -> row
      other -> flunk("Expected one row, got: #{inspect(other)}")
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)
  defp to_int(_), do: 0
end
