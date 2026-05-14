defmodule Spectabas.Analytics.SegmentTest do
  use ExUnit.Case, async: true

  alias Spectabas.Analytics.Segment

  describe "to_sql/1" do
    test "returns empty string for nil" do
      assert Segment.to_sql(nil) == ""
    end

    test "returns empty string for empty list" do
      assert Segment.to_sql([]) == ""
    end

    test "generates IS clause" do
      filters = [%{"field" => "ip_country", "op" => "is", "value" => "US"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "ip_country = 'US'"
    end

    test "generates IS NOT clause" do
      filters = [%{"field" => "browser", "op" => "is_not", "value" => "Chrome"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "browser != 'Chrome'"
    end

    test "generates CONTAINS clause" do
      filters = [%{"field" => "url_path", "op" => "contains", "value" => "/blog"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "url_path LIKE '%/blog%'"
    end

    test "generates NOT CONTAINS clause" do
      filters = [%{"field" => "referrer_domain", "op" => "not_contains", "value" => "google"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "referrer_domain NOT LIKE '%google%'"
    end

    test "combines multiple filters" do
      filters = [
        %{"field" => "ip_country", "op" => "is", "value" => "US"},
        %{"field" => "browser", "op" => "is", "value" => "Chrome"}
      ]

      sql = Segment.to_sql(filters)
      assert sql =~ "ip_country = 'US'"
      assert sql =~ "browser = 'Chrome'"
    end

    test "rejects invalid fields" do
      filters = [%{"field" => "DROP TABLE", "op" => "is", "value" => "bad"}]
      assert Segment.to_sql(filters) == ""
    end

    test "rejects empty values" do
      filters = [%{"field" => "ip_country", "op" => "is", "value" => ""}]
      assert Segment.to_sql(filters) == ""
    end

    test "rejects invalid operators" do
      filters = [%{"field" => "ip_country", "op" => "DROP", "value" => "US"}]
      assert Segment.to_sql(filters) == ""
    end

    test "escapes single quotes in values" do
      filters = [%{"field" => "url_path", "op" => "is", "value" => "it's"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "it\\'s"
    end

    test "escapes LIKE wildcards in contains operator" do
      filters = [%{"field" => "url_path", "op" => "contains", "value" => "100%_done"}]
      sql = Segment.to_sql(filters)
      # % and _ escaped with backslash, then ClickHouse.param escapes the backslash too
      assert sql =~ "LIKE"
      refute sql =~ "'%100%_done%'"
    end

    test "escapes LIKE wildcards in not_contains operator" do
      filters = [%{"field" => "url_path", "op" => "not_contains", "value" => "50%"}]
      sql = Segment.to_sql(filters)
      assert sql =~ "NOT LIKE"
      refute sql =~ "'%50%%'"
    end
  end

  describe "available_fields/0" do
    test "returns a list of field maps" do
      fields = Segment.available_fields()
      assert is_list(fields)
      assert length(fields) > 10

      assert Enum.any?(fields, fn f -> f.field == "ip_country" end)
      assert Enum.any?(fields, fn f -> f.field == "browser" end)
      assert Enum.any?(fields, fn f -> f.field == "url_path" end)
    end

    test "each field has field and label keys" do
      for f <- Segment.available_fields() do
        assert is_binary(f.field)
        assert is_binary(f.label)
      end
    end
  end

  describe "form virtual fields" do
    test "form_submitted expands to a visitor_id IN subquery scoped to site_id + form_id" do
      filters = [%{"field" => "form_submitted", "op" => "is", "value" => "contact"}]
      sql = Segment.to_sql(filters, site_id: 42)

      assert sql =~ "visitor_id IN"
      assert sql =~ "_form_submit"
      assert sql =~ "site_id = "
      assert sql =~ "'contact'"
      assert sql =~ "_form_id"
    end

    test "form_abandoned excludes submitters via NOT IN" do
      filters = [%{"field" => "form_abandoned", "op" => "is", "value" => "signup"}]
      sql = Segment.to_sql(filters, site_id: 42)

      assert sql =~ "visitor_id IN"
      assert sql =~ "NOT IN"
      assert sql =~ "_form_start"
      assert sql =~ "_form_submit"
    end

    test "form_submitted is_not flips with NOT" do
      filters = [%{"field" => "form_submitted", "op" => "is_not", "value" => "contact"}]
      sql = Segment.to_sql(filters, site_id: 42)
      assert sql =~ "NOT ("
    end

    test "form virtual fields drop when no site_id provided" do
      filters = [
        %{"field" => "form_submitted", "op" => "is", "value" => "contact"},
        %{"field" => "form_abandoned", "op" => "is", "value" => "signup"}
      ]

      assert Segment.to_sql(filters) == ""
    end

    test "form virtual fields drop when form_id is blank" do
      filters = [%{"field" => "form_submitted", "op" => "is", "value" => ""}]
      assert Segment.to_sql(filters, site_id: 42) == ""
    end
  end
end
