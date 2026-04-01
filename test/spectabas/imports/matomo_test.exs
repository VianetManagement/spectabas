defmodule Spectabas.Imports.MatomoTest do
  use ExUnit.Case, async: true

  alias Spectabas.Imports.Matomo

  describe "module API" do
    test "defines import_day/5" do
      Code.ensure_loaded!(Matomo)
      assert function_exported?(Matomo, :import_day, 5)
    end

    test "defines import_range/6" do
      Code.ensure_loaded!(Matomo)
      assert function_exported?(Matomo, :import_range, 6)
    end

    test "defines rollback/1" do
      Code.ensure_loaded!(Matomo)
      assert function_exported?(Matomo, :rollback, 1)
    end

    test "defines imported_day_count/1" do
      Code.ensure_loaded!(Matomo)
      assert function_exported?(Matomo, :imported_day_count, 1)
    end
  end
end
