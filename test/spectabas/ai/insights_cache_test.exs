defmodule Spectabas.AI.InsightsCacheTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.AI.InsightsCache

  import Spectabas.AccountsFixtures

  setup do
    account = test_account()

    site =
      Repo.insert!(%Spectabas.Sites.Site{
        name: "Cache Test Site",
        domain: "b.cache-test.com",
        public_key: "cache_#{System.unique_integer([:positive])}",
        active: true,
        account_id: account.id
      })

    %{site: site}
  end

  describe "put/4" do
    test "creates a new cache entry", %{site: site} do
      assert {:ok, entry} = InsightsCache.put(site.id, "Test insights content", "anthropic", "claude-haiku-4-5-20251001")

      assert entry.site_id == site.id
      assert entry.content == "Test insights content"
      assert entry.provider == "anthropic"
      assert entry.model == "claude-haiku-4-5-20251001"
      assert entry.generated_at != nil
    end

    test "updates existing entry for same site_id", %{site: site} do
      {:ok, first} = InsightsCache.put(site.id, "First content", "anthropic", "claude-haiku-4-5-20251001")
      {:ok, second} = InsightsCache.put(site.id, "Updated content", "openai", "gpt-4o-mini")

      assert first.id == second.id
      assert second.content == "Updated content"
      assert second.provider == "openai"
      assert second.model == "gpt-4o-mini"
    end

    test "different sites get separate entries", %{site: site} do
      account = test_account()

      site2 =
        Repo.insert!(%Spectabas.Sites.Site{
          name: "Cache Test Site 2",
          domain: "b.cache-test2.com",
          public_key: "cache2_#{System.unique_integer([:positive])}",
          active: true,
          account_id: account.id
        })

      {:ok, entry1} = InsightsCache.put(site.id, "Site 1 insights", "anthropic", "claude-haiku-4-5-20251001")
      {:ok, entry2} = InsightsCache.put(site2.id, "Site 2 insights", "openai", "gpt-4o-mini")

      assert entry1.id != entry2.id
      assert entry1.site_id == site.id
      assert entry2.site_id == site2.id
    end
  end

  describe "get/1" do
    test "returns cached entry within 24h", %{site: site} do
      {:ok, _entry} = InsightsCache.put(site.id, "Fresh insights", "anthropic", "claude-haiku-4-5-20251001")

      result = InsightsCache.get(site.id)
      assert result != nil
      assert result.content == "Fresh insights"
      assert result.provider == "anthropic"
      assert result.model == "claude-haiku-4-5-20251001"
    end

    test "returns nil when no cache entry exists", %{site: site} do
      assert InsightsCache.get(site.id) == nil
    end

    test "returns nil for expired entries (older than 24h)", %{site: site} do
      {:ok, entry} = InsightsCache.put(site.id, "Old insights", "anthropic", "claude-haiku-4-5-20251001")

      # Manually set generated_at to 25 hours ago to simulate expiry
      expired_at = DateTime.add(DateTime.utc_now(), -25 * 3600, :second) |> DateTime.truncate(:second)

      entry
      |> Ecto.Changeset.change(%{generated_at: expired_at})
      |> Repo.update!()

      assert InsightsCache.get(site.id) == nil
    end

    test "returns entry that is exactly at the boundary (23h59m ago)", %{site: site} do
      {:ok, entry} = InsightsCache.put(site.id, "Borderline insights", "openai", "gpt-4o-mini")

      # Set generated_at to 23 hours and 59 minutes ago (still within 24h)
      almost_expired_at = DateTime.add(DateTime.utc_now(), -(23 * 3600 + 59 * 60), :second) |> DateTime.truncate(:second)

      entry
      |> Ecto.Changeset.change(%{generated_at: almost_expired_at})
      |> Repo.update!()

      result = InsightsCache.get(site.id)
      assert result != nil
      assert result.content == "Borderline insights"
    end

    test "returns nil for a non-existent site_id" do
      assert InsightsCache.get(-1) == nil
    end
  end
end
