defmodule Spectabas.AdIntegrations.Platforms.BingWebmasterTest do
  use ExUnit.Case, async: true

  alias Spectabas.AdIntegrations.Platforms.BingWebmaster

  describe "parse_bing_date/1" do
    test "parses /Date(ms-offset)/ format with timezone offset" do
      # 1734681600000 ms = 2024-12-20T08:00:00Z
      assert BingWebmaster.parse_bing_date("/Date(1734681600000-0800)/") == "2024-12-20"
    end

    test "parses /Date(ms+offset)/ format with positive timezone offset" do
      # Same epoch, positive offset — date extraction is based on UTC epoch only
      assert BingWebmaster.parse_bing_date("/Date(1734681600000+0530)/") == "2024-12-20"
    end

    test "parses /Date(ms)/ format without timezone offset" do
      assert BingWebmaster.parse_bing_date("/Date(1734681600000)/") == "2024-12-20"
    end

    test "parses epoch 0 correctly" do
      assert BingWebmaster.parse_bing_date("/Date(0)/") == "1970-01-01"
    end

    test "returns empty string for nil" do
      assert BingWebmaster.parse_bing_date(nil) == ""
    end

    test "returns first 10 chars for unknown format" do
      assert BingWebmaster.parse_bing_date("2024-12-20T00:00:00Z") == "2024-12-20"
    end

    test "returns first 10 chars for plain ISO date" do
      assert BingWebmaster.parse_bing_date("2024-12-20") == "2024-12-20"
    end

    test "truncates longer unknown format strings to 10 chars" do
      assert BingWebmaster.parse_bing_date("some-unknown-date-format") == "some-unkno"
    end
  end
end
