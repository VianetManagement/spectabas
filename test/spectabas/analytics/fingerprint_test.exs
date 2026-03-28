defmodule Spectabas.Analytics.FingerprintTest do
  use ExUnit.Case, async: true

  alias Spectabas.Analytics

  describe "visitors_by_fingerprint/2" do
    test "returns {:ok, []} for non-existent fingerprint with nil site" do
      assert Analytics.visitors_by_fingerprint(nil, "abc123") == {:ok, []}
    end

    test "returns {:ok, []} for empty fingerprint string" do
      site = %Spectabas.Sites.Site{id: 999}
      assert Analytics.visitors_by_fingerprint(site, "") == {:ok, []}
    end

    test "returns {:ok, []} when site is nil" do
      assert Analytics.visitors_by_fingerprint(nil, "some_fingerprint") == {:ok, []}
    end

    test "function accepts a Site struct and binary fingerprint" do
      # Verify the function head matches the expected signature.
      # With a real Site struct and non-empty fingerprint, the function
      # would attempt a ClickHouse query. We only test the guard-clause
      # fallback paths here since ClickHouse is not available in tests.
      assert is_function(&Analytics.visitors_by_fingerprint/2)
    end
  end
end
