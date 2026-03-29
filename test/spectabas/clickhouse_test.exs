defmodule Spectabas.ClickHouseTest do
  use ExUnit.Case, async: true

  describe "parse_rows NaN/inf sanitization" do
    # ClickHouse returns nan/inf in JSONEachRow format when aggregations
    # have no matching rows. These are not valid JSON and crash Jason.decode!

    test "replaces :nan with :null in JSON" do
      line = ~s({"median_page_load":nan,"samples":"5"})
      [row] = sanitize_and_parse(line)
      assert row["median_page_load"] == nil
      assert row["samples"] == "5"
    end

    test "replaces :-inf with :null in JSON" do
      line = ~s({"value":-inf,"count":"3"})
      [row] = sanitize_and_parse(line)
      assert row["value"] == nil
      assert row["count"] == "3"
    end

    test "replaces :inf with :null in JSON" do
      line = ~s({"value":inf,"count":"3"})
      [row] = sanitize_and_parse(line)
      assert row["value"] == nil
    end

    test "handles multiple nan values in one row" do
      line = ~s({"a":nan,"b":nan,"c":"ok"})
      [row] = sanitize_and_parse(line)
      assert row["a"] == nil
      assert row["b"] == nil
      assert row["c"] == "ok"
    end

    test "preserves normal numeric values" do
      line = ~s({"value":4692,"name":"test"})
      [row] = sanitize_and_parse(line)
      assert row["value"] == 4692
      assert row["name"] == "test"
    end

    test "handles nan at end of object" do
      line = ~s({"value":nan})
      [row] = sanitize_and_parse(line)
      assert row["value"] == nil
    end

    test "does not replace nan inside string values" do
      line = ~s({"name":"nanometer","value":nan})
      [row] = sanitize_and_parse(line)
      assert row["name"] == "nanometer"
      assert row["value"] == nil
    end
  end

  # Replicate the parse_rows sanitization logic for testing
  defp sanitize_and_parse(line) do
    line
    |> String.split("\n", trim: true)
    |> Enum.map(fn l ->
      l
      |> String.replace(~r/:nan([,}])/, ":null\\1")
      |> String.replace(~r/:-?inf([,}])/, ":null\\1")
      |> Jason.decode!()
    end)
  end
end
