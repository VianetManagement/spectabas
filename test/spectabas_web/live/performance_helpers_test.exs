defmodule SpectabasWeb.Dashboard.PerformanceHelpersTest do
  use ExUnit.Case, async: true

  alias SpectabasWeb.Dashboard.PerformanceLive

  describe "vital_score/3" do
    test "scores as Good when p75 is under good threshold" do
      # LCP: good < 2500ms
      assert PerformanceLive.vital_score(1500, 2500, 4000) == "Good"
      assert PerformanceLive.vital_score(2500, 2500, 4000) == "Good"
    end

    test "scores as Needs Work when p75 is between good and poor" do
      assert PerformanceLive.vital_score(3000, 2500, 4000) == "Needs Work"
      assert PerformanceLive.vital_score(4000, 2500, 4000) == "Needs Work"
    end

    test "scores as Poor when p75 exceeds poor threshold" do
      assert PerformanceLive.vital_score(5000, 2500, 4000) == "Poor"
    end

    test "LCP thresholds (2500ms good, 4000ms poor)" do
      assert PerformanceLive.vital_score(2000, 2500, 4000) == "Good"
      assert PerformanceLive.vital_score(3500, 2500, 4000) == "Needs Work"
      assert PerformanceLive.vital_score(4500, 2500, 4000) == "Poor"
    end

    test "CLS thresholds (0.1 good, 0.25 poor)" do
      assert PerformanceLive.vital_score(0.05, 0.1, 0.25) == "Good"
      assert PerformanceLive.vital_score(0.1, 0.1, 0.25) == "Good"
      assert PerformanceLive.vital_score(0.15, 0.1, 0.25) == "Needs Work"
      assert PerformanceLive.vital_score(0.3, 0.1, 0.25) == "Poor"
    end

    test "FID thresholds (100ms good, 300ms poor)" do
      assert PerformanceLive.vital_score(50, 100, 300) == "Good"
      assert PerformanceLive.vital_score(200, 100, 300) == "Needs Work"
      assert PerformanceLive.vital_score(500, 100, 300) == "Poor"
    end

    test "edge case: zero value" do
      assert PerformanceLive.vital_score(0, 2500, 4000) == "Good"
      assert PerformanceLive.vital_score(0, 0.1, 0.25) == "Good"
    end
  end

  describe "format_ms/1" do
    test "formats sub-second values as milliseconds" do
      assert PerformanceLive.format_ms(45) == "45ms"
      assert PerformanceLive.format_ms(999) == "999ms"
    end

    test "formats values >= 1000 as seconds" do
      assert PerformanceLive.format_ms(1000) == "1.0s"
      assert PerformanceLive.format_ms(1500) == "1.5s"
      assert PerformanceLive.format_ms(2345) == "2.3s"
    end

    test "handles zero" do
      assert PerformanceLive.format_ms(0) == "0ms"
    end

    test "handles string input (ClickHouse returns strings)" do
      assert PerformanceLive.format_ms("1234") == "1.2s"
      assert PerformanceLive.format_ms("45") == "45ms"
    end

    test "handles nil" do
      assert PerformanceLive.format_ms(nil) == "0ms"
    end
  end

  describe "format_bytes/1" do
    test "formats megabytes" do
      assert PerformanceLive.format_bytes(1_500_000) == "1.5MB"
      assert PerformanceLive.format_bytes(2_000_000) == "2.0MB"
    end

    test "formats kilobytes" do
      assert PerformanceLive.format_bytes(1500) == "1.5KB"
      assert PerformanceLive.format_bytes(54321) == "54.3KB"
    end

    test "formats bytes" do
      assert PerformanceLive.format_bytes(500) == "500B"
    end

    test "shows dash for zero" do
      assert PerformanceLive.format_bytes(0) == "-"
    end

    test "handles string input" do
      assert PerformanceLive.format_bytes("54321") == "54.3KB"
    end

    test "handles nil" do
      assert PerformanceLive.format_bytes(nil) == "-"
    end
  end

  describe "to_num/1" do
    test "passes through integers" do
      assert PerformanceLive.to_num(42) == 42
    end

    test "truncates floats" do
      assert PerformanceLive.to_num(42.7) == 42
    end

    test "parses string integers" do
      assert PerformanceLive.to_num("1234") == 1234
    end

    test "returns 0 for unparseable strings" do
      assert PerformanceLive.to_num("abc") == 0
      assert PerformanceLive.to_num("") == 0
    end

    test "returns 0 for nil" do
      assert PerformanceLive.to_num(nil) == 0
    end
  end

  describe "to_float/1" do
    test "passes through floats" do
      assert PerformanceLive.to_float(0.05) == 0.05
    end

    test "converts integers to float" do
      assert PerformanceLive.to_float(42) == 42.0
    end

    test "parses string floats" do
      assert PerformanceLive.to_float("0.05") == 0.05
      assert PerformanceLive.to_float("3.14") == 3.14
    end

    test "returns 0.0 for unparseable strings" do
      assert PerformanceLive.to_float("abc") == 0.0
    end

    test "returns 0.0 for nil" do
      assert PerformanceLive.to_float(nil) == 0.0
    end
  end
end
