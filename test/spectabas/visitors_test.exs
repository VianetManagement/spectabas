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

  describe "scraper_manual_flag" do
    test "defaults to false on a new visitor", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-mf-1", :off, "1.2.3.4")
      assert visitor.scraper_manual_flag == false
    end

    test "changeset accepts scraper_manual_flag = true", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-mf-2", :off, "1.2.3.4")

      {:ok, updated} =
        visitor
        |> Visitor.changeset(%{
          scraper_manual_flag: true,
          scraper_webhook_score: 100,
          scraper_webhook_sent_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Spectabas.Repo.update()

      assert updated.scraper_manual_flag == true
      assert updated.scraper_webhook_score == 100
    end

    test "changeset can clear scraper_manual_flag back to false", %{site: site} do
      {:ok, visitor} = Visitors.get_or_create(site.id, "cookie-mf-3", :off, "1.2.3.4")

      {:ok, flagged} =
        visitor
        |> Visitor.changeset(%{scraper_manual_flag: true})
        |> Spectabas.Repo.update()

      assert flagged.scraper_manual_flag == true

      {:ok, cleared} =
        flagged
        |> Visitor.changeset(%{
          scraper_manual_flag: false,
          scraper_webhook_sent_at: nil,
          scraper_webhook_score: nil
        })
        |> Spectabas.Repo.update()

      assert cleared.scraper_manual_flag == false
      assert is_nil(cleared.scraper_webhook_sent_at)
      assert is_nil(cleared.scraper_webhook_score)
    end
  end

  describe "scraper whitelist propagation by email" do
    test "identify inherits whitelist from another visitor with the same email", %{site: site} do
      # Original whitelisted visitor
      {:ok, v1} = Visitors.get_or_create(site.id, "cookie-wl-1", :off, "1.2.3.4")

      {:ok, _} =
        Visitors.identify(site.id, v1.cookie_id, %{"email" => "Jeff@Example.com"}, "1.2.3.4")

      v1 = Spectabas.Repo.get!(Visitor, v1.id)

      {:ok, _} =
        v1
        |> Visitor.changeset(%{scraper_whitelisted: true})
        |> Spectabas.Repo.update()

      # New visitor (different cookie / "device") identifies with the same email
      {:ok, v2} = Visitors.get_or_create(site.id, "cookie-wl-2", :off, "5.6.7.8")
      assert v2.scraper_whitelisted == false

      {:ok, v2_updated} =
        Visitors.identify(site.id, v2.cookie_id, %{"email" => "jeff@example.com"}, "5.6.7.8")

      assert v2_updated.scraper_whitelisted == true
    end

    test "identify does not inherit when no matching whitelisted email exists", %{site: site} do
      {:ok, v1} = Visitors.get_or_create(site.id, "cookie-wl-3", :off, "1.2.3.4")

      {:ok, _} =
        v1
        |> Visitor.changeset(%{
          email: "alice@example.com",
          scraper_whitelisted: true
        })
        |> Spectabas.Repo.update()

      {:ok, v2} = Visitors.get_or_create(site.id, "cookie-wl-4", :off, "5.6.7.8")

      {:ok, v2_updated} =
        Visitors.identify(site.id, v2.cookie_id, %{"email" => "bob@example.com"}, "5.6.7.8")

      assert v2_updated.scraper_whitelisted == false
    end

    test "propagate_whitelist_by_email/3 updates sibling records and skips self", %{site: site} do
      {:ok, v1} = Visitors.get_or_create(site.id, "cookie-wl-5", :off, "1.2.3.4")
      {:ok, v2} = Visitors.get_or_create(site.id, "cookie-wl-6", :off, "1.2.3.4")
      {:ok, v3} = Visitors.get_or_create(site.id, "cookie-wl-7", :off, "1.2.3.4")

      {:ok, v1} =
        v1 |> Visitor.changeset(%{email: "carol@example.com"}) |> Spectabas.Repo.update()

      {:ok, _} =
        v2 |> Visitor.changeset(%{email: "carol@example.com"}) |> Spectabas.Repo.update()

      {:ok, _} =
        v3 |> Visitor.changeset(%{email: "dan@example.com"}) |> Spectabas.Repo.update()

      assert Visitors.propagate_whitelist_by_email(site.id, v1, true) == 1

      v2_after = Spectabas.Repo.get!(Visitor, v2.id)
      v3_after = Spectabas.Repo.get!(Visitor, v3.id)
      assert v2_after.scraper_whitelisted == true
      assert v3_after.scraper_whitelisted == false
    end

    test "propagate_whitelist_by_email/3 is a no-op for visitors without an email", %{site: site} do
      {:ok, v1} = Visitors.get_or_create(site.id, "cookie-wl-8", :off, "1.2.3.4")
      assert Visitors.propagate_whitelist_by_email(site.id, v1, true) == 0
    end
  end
end
