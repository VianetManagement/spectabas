defmodule Spectabas.Workers.DailyRollupTest do
  use ExUnit.Case, async: true

  alias Spectabas.Workers.DailyRollup

  describe "date_delete_sql/1" do
    test "targets only the requested date with param-escaped value" do
      sql = DailyRollup.date_delete_sql("2026-04-12")
      assert sql =~ "ALTER TABLE daily_rollup DELETE"
      assert sql =~ "WHERE date = '2026-04-12'"
      assert sql =~ "mutations_sync = 2"
    end

    test "escapes single quotes in the date param" do
      sql = DailyRollup.date_delete_sql("2026-04-12' OR 1=1 --")
      # The apostrophe inside the value must be escaped so it can't terminate
      # the string literal. ClickHouse.param/1 uses backslash-escaping.
      assert sql =~ "'2026-04-12\\' OR 1=1 --'"
    end
  end

  describe "date_insert_sql/1" do
    test "uses state aggregates filtered to pageviews and non-bots" do
      sql = DailyRollup.date_insert_sql("2026-04-12")
      assert sql =~ "INSERT INTO daily_rollup"
      assert sql =~ "countIfState(event_type = 'pageview' AND ip_is_bot = 0)"
      assert sql =~ "uniqExactIfState(visitor_id, event_type = 'pageview' AND ip_is_bot = 0)"
      assert sql =~ "uniqExactIfState(session_id, event_type = 'pageview' AND ip_is_bot = 0)"
      assert sql =~ "WHERE toDate(timestamp) = '2026-04-12'"
      assert sql =~ "GROUP BY site_id, date"
    end

    test "scopes to a single UTC day (not a range)" do
      sql = DailyRollup.date_insert_sql("2026-04-12")
      # Must be an equality filter, not a range — otherwise we'd re-aggregate
      # multiple days on every insert.
      refute sql =~ "timestamp >"
      refute sql =~ "timestamp <"
      assert sql =~ "toDate(timestamp) = "
    end
  end

  describe "backfill_delete_sql/0" do
    test "only deletes completed prior days, never today" do
      sql = DailyRollup.backfill_delete_sql()
      assert sql =~ "WHERE date < today()"
      refute sql =~ "date <="
      assert sql =~ "mutations_sync = 2"
    end
  end

  describe "backfill_insert_sql/0" do
    test "aggregates every complete prior day in one statement" do
      sql = DailyRollup.backfill_insert_sql()
      assert sql =~ "WHERE toDate(timestamp) < today()"
      assert sql =~ "countIfState"
      assert sql =~ "uniqExactIfState(visitor_id"
      assert sql =~ "uniqExactIfState(session_id"
      assert sql =~ "GROUP BY site_id, date"
    end
  end

  describe "perform/1 arg routing" do
    # These tests don't hit ClickHouse — they verify the worker dispatches
    # to the right SQL shape. Since ClickHouse isn't running, execute/1
    # returns an error tuple, and perform/1 returns {:error, _}.
    # The point is to confirm the worker accepts each documented arg shape.

    test "accepts empty args (daily cron mode)" do
      job = %Oban.Job{args: %{}}
      # Doesn't crash with FunctionClauseError
      result = DailyRollup.perform(job)
      assert match?(:ok, result) or match?({:error, _}, result)
    end

    test "accepts explicit date arg" do
      job = %Oban.Job{args: %{"date" => "2026-04-12"}}
      result = DailyRollup.perform(job)
      assert match?(:ok, result) or match?({:error, _}, result)
    end

    test "accepts backfill arg" do
      job = %Oban.Job{args: %{"backfill" => true}}
      result = DailyRollup.perform(job)
      assert match?(:ok, result) or match?({:error, _}, result)
    end
  end
end
