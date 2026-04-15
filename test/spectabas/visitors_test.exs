defmodule Spectabas.VisitorsTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.Visitors
  alias Spectabas.Visitors.Visitor

  setup do
    # Create a site for all tests
    {:ok, site} =
      Spectabas.Sites.create_site(%{
        name: "Test Site",
        domain: "b.test-xid.com",
        account_id: 1
      })

    %{site: site}
  end

  describe "find_by_external_id/2" do
    test "returns visitor when external_id matches", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-abc", :off, "1.2.3.4")
      Visitors.set_external_id(visitor, "xid-123")

      found = Visitors.find_by_external_id(site.id, "xid-123")
      assert found.id == visitor.id
    end

    test "returns nil when no match", %{site: site} do
      {:ok, _visitor} = Visitors.get_or_create(site.id, "cookie-abc", :off, "1.2.3.4")
      assert Visitors.find_by_external_id(site.id, "nonexistent") == nil
    end

    test "returns nil for empty string" do
      assert Visitors.find_by_external_id(1, "") == nil
    end

    test "returns nil for nil" do
      assert Visitors.find_by_external_id(1, nil) == nil
    end

    test "scopes to site_id", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-abc", :off, "1.2.3.4")
      Visitors.set_external_id(visitor, "xid-456")

      # Different site_id should not find it
      assert Visitors.find_by_external_id(site.id + 999, "xid-456") == nil
      # Same site_id should find it
      assert Visitors.find_by_external_id(site.id, "xid-456") != nil
    end
  end

  describe "set_external_id/2" do
    test "sets external_id on visitor", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-set1", :off, "1.2.3.4")
      assert visitor.external_id == nil

      {:ok, updated} = Visitors.set_external_id(visitor, "my-ext-id")
      assert updated.external_id == "my-ext-id"
    end

    test "silently handles conflict when another visitor has same external_id", %{site: site} do
      {:ok, v1} = Visitors.get_or_create(site.id, "cookie-v1", :off, "1.2.3.4")
      {:ok, v2} = Visitors.get_or_create(site.id, "cookie-v2", :off, "1.2.3.5")

      {:ok, _} = Visitors.set_external_id(v1, "shared-xid")
      # Second call should not crash
      {:ok, _} = Visitors.set_external_id(v2, "shared-xid")
    end

    test "no-ops for nil external_id", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-nil", :off, "1.2.3.4")
      {:ok, unchanged} = Visitors.set_external_id(visitor, nil)
      assert unchanged.external_id == nil
    end

    test "no-ops for empty string", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-empty", :off, "1.2.3.4")
      {:ok, unchanged} = Visitors.set_external_id(visitor, "")
      assert unchanged.external_id == nil
    end
  end

  describe "external_id visitor merge flow" do
    test "visitor retains identity across cookie changes via external_id", %{site: site} do
      # First visit: cookie-A with external_id "puppies-fp-123"
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-A", :off, "1.2.3.4")
      {:ok, visitor} = Visitors.set_external_id(visitor, "puppies-fp-123")

      # Later: cookie cleared, new cookie-B arrives with same external_id
      found = Visitors.find_by_external_id(site.id, "puppies-fp-123")
      assert found.id == visitor.id
      assert found.cookie_id == "cookie-A"

      # Merge: update cookie_id to the new cookie
      {:ok, merged} =
        found
        |> Visitor.changeset(%{cookie_id: "cookie-B"})
        |> Repo.update()

      assert merged.id == visitor.id
      assert merged.cookie_id == "cookie-B"
      assert merged.external_id == "puppies-fp-123"

      # Subsequent lookup by new cookie should find the same visitor
      {:ok, same_visitor} = Visitors.get_or_create(site.id, "cookie-B", :off, "1.2.3.4")
      assert same_visitor.id == visitor.id
    end
  end
end
