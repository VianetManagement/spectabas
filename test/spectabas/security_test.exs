defmodule Spectabas.SecurityTest do
  use ExUnit.Case, async: true

  alias Spectabas.ClickHouse

  describe "ClickHouse.param/1 security" do
    test "escapes single quotes" do
      assert ClickHouse.param("it's") == "'it\\'s'"
    end

    test "escapes backslashes" do
      assert ClickHouse.param("path\\to") == "'path\\\\to'"
    end

    test "strips null bytes" do
      assert ClickHouse.param("hello\0world") == "'helloworld'"
    end

    test "handles integers" do
      assert ClickHouse.param(42) == "42"
    end

    test "handles floats" do
      assert ClickHouse.param(3.14) == "3.14"
    end

    test "handles nil" do
      assert ClickHouse.param(nil) == "NULL"
    end

    test "prevents SQL injection via string" do
      result = ClickHouse.param("'; DROP TABLE events; --")
      # The quote is escaped with backslash, so it's safe
      assert result == "'\\'; DROP TABLE events; --'"
      # The opening quote is escaped (preceded by backslash)
      assert String.starts_with?(result, "'\\'")
    end
  end

  describe "Segment field validation" do
    alias Spectabas.Analytics.Segment

    test "rejects SQL injection in field name" do
      filters = [%{"field" => "1; DROP TABLE events", "op" => "is", "value" => "test"}]
      assert Segment.to_sql(filters) == ""
    end

    test "rejects unknown fields" do
      filters = [%{"field" => "secret_column", "op" => "is", "value" => "test"}]
      assert Segment.to_sql(filters) == ""
    end

    test "rejects invalid operators" do
      filters = [%{"field" => "browser", "op" => "LIKE ''; DROP", "value" => "test"}]
      assert Segment.to_sql(filters) == ""
    end

    test "allows valid segment filter" do
      filters = [%{"field" => "browser", "op" => "is", "value" => "Chrome"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "browser = 'Chrome'"
    end

    test "visitor_intent is an allowed field" do
      filters = [%{"field" => "visitor_intent", "op" => "is", "value" => "buying"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "visitor_intent = 'buying'"
    end

    test "ip_asn is an allowed field" do
      filters = [%{"field" => "ip_asn", "op" => "is", "value" => "15169"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "ip_asn = '15169'"
    end
  end
end
