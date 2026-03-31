defmodule Spectabas.Visitors.CacheTest do
  use ExUnit.Case, async: true

  alias Spectabas.Visitors.Cache

  describe "get/put" do
    test "returns nil for missing key" do
      assert Cache.get(999, "nonexistent_cookie") == nil
    end

    test "stores and retrieves a visitor_id" do
      Cache.put(1, "cookie_abc", "visitor_uuid_123")
      assert Cache.get(1, "cookie_abc") == "visitor_uuid_123"
    end

    test "different sites don't collide" do
      Cache.put(1, "same_cookie", "visitor_a")
      Cache.put(2, "same_cookie", "visitor_b")
      assert Cache.get(1, "same_cookie") == "visitor_a"
      assert Cache.get(2, "same_cookie") == "visitor_b"
    end

    test "overwrites existing value" do
      Cache.put(1, "cookie_x", "old_visitor")
      Cache.put(1, "cookie_x", "new_visitor")
      assert Cache.get(1, "cookie_x") == "new_visitor"
    end

    test "size returns count of entries" do
      initial = Cache.size()
      Cache.put(99, "size_test_1", "v1")
      Cache.put(99, "size_test_2", "v2")
      assert Cache.size() >= initial + 2
    end
  end
end
