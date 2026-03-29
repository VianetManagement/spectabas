defmodule Spectabas.TimezoneTest do
  use ExUnit.Case, async: true

  alias Spectabas.Analytics

  describe "timezone database is configured" do
    test "can convert UTC to named timezone" do
      assert {:ok, dt} = DateTime.shift_zone(~U[2026-03-28 12:00:00Z], "America/New_York")
      assert dt.time_zone == "America/New_York"
    end

    test "can get current time in named timezone" do
      assert {:ok, dt} = DateTime.now("America/New_York")
      assert dt.time_zone == "America/New_York"
    end

    test "can create DateTime in named timezone" do
      assert {:ok, dt} = DateTime.new(~D[2026-03-28], ~T[00:00:00], "America/New_York")
      assert dt.time_zone == "America/New_York"
    end

    test "shift_zone handles common analytics timezones" do
      timezones = [
        "America/New_York",
        "America/Chicago",
        "America/Denver",
        "America/Los_Angeles",
        "Europe/London",
        "Europe/Berlin",
        "Asia/Tokyo",
        "Australia/Sydney",
        "UTC"
      ]

      for tz <- timezones do
        assert {:ok, _} = DateTime.shift_zone(~U[2026-06-15 12:00:00Z], tz),
               "Failed to shift to #{tz}"
      end
    end
  end

  describe "period_to_date_range/2 with timezone" do
    test ":today uses site timezone for midnight boundary" do
      range = Analytics.period_to_date_range(:today, "America/New_York")

      # The from should be midnight Eastern converted to UTC
      # In EDT (UTC-4), midnight = 04:00 UTC
      assert range.from.hour == 4 || range.from.hour == 5,
             "Expected from.hour to be 4 (EDT) or 5 (EST), got #{range.from.hour}"

      assert DateTime.compare(range.from, range.to) == :lt
    end

    test ":today with UTC timezone starts at midnight UTC" do
      range = Analytics.period_to_date_range(:today, "UTC")
      assert range.from.hour == 0
      assert range.from.minute == 0
    end

    test ":today with Asia/Tokyo is ahead of UTC" do
      range = Analytics.period_to_date_range(:today, "Asia/Tokyo")

      # Tokyo is UTC+9, so midnight Tokyo = 15:00 UTC previous day
      # from.hour should be 15 (of the previous day in UTC)
      assert range.from.hour == 15,
             "Expected from.hour to be 15 (JST midnight in UTC), got #{range.from.hour}"
    end

    test ":day (24h) is timezone-independent rolling window" do
      range_utc = Analytics.period_to_date_range(:day, "UTC")
      range_ny = Analytics.period_to_date_range(:day, "America/New_York")

      # Both should be ~24 hours ago, regardless of timezone
      diff_utc = DateTime.diff(range_utc.to, range_utc.from, :second)
      diff_ny = DateTime.diff(range_ny.to, range_ny.from, :second)

      # Within 2 seconds of each other (execution time difference)
      assert abs(diff_utc - diff_ny) < 2
      # Both ~24 hours
      assert abs(diff_utc - 86400) < 2
    end

    test ":week is timezone-independent rolling window" do
      range = Analytics.period_to_date_range(:week, "America/New_York")
      diff = DateTime.diff(range.to, range.from, :second)
      # 7 days = 604800 seconds, within 2 seconds
      assert abs(diff - 604_800) < 2
    end

    test "invalid timezone falls back to UTC" do
      range = Analytics.period_to_date_range(:today, "Invalid/Timezone")
      assert range.from.hour == 0
    end
  end
end
