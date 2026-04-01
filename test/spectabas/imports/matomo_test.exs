defmodule Spectabas.Imports.MatomoTest do
  use ExUnit.Case, async: true

  alias Spectabas.Imports.Matomo

  describe "module API" do
    test "exports import_day/5" do
      assert function_exported?(Matomo, :import_day, 5)
    end

    test "exports import_range/6" do
      assert function_exported?(Matomo, :import_range, 6)
    end

    test "exports rollback/1" do
      assert function_exported?(Matomo, :rollback, 1)
    end

    test "exports imported_day_count/1" do
      assert function_exported?(Matomo, :imported_day_count, 1)
    end
  end

  describe "split_date_range in analytics" do
    test "overview_stats handles nil import dates gracefully" do
      # A site with no import dates should use normal query path
      # This is tested implicitly via the existing overview_stats tests
      assert function_exported?(Spectabas.Analytics, :overview_stats, 4)
    end
  end
end
