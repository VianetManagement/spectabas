defmodule Spectabas.SegmentsTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.Segments
  import Spectabas.AccountsFixtures

  setup do
    user =
      Spectabas.Repo.insert!(%Spectabas.Accounts.User{
        email: "seg-test-#{System.unique_integer([:positive])}@test.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        role: :analyst
      })

    other_user =
      Spectabas.Repo.insert!(%Spectabas.Accounts.User{
        email: "seg-other-#{System.unique_integer([:positive])}@test.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        role: :analyst
      })

    site =
      Spectabas.Repo.insert!(%Spectabas.Sites.Site{
        name: "Test Site",
        domain: "b.test-seg.com",
        public_key: "seg_key_#{System.unique_integer([:positive])}",
        active: true,
        gdpr_mode: "off",
        account_id: test_account().id
      })

    %{user: user, other_user: other_user, site: site}
  end

  describe "save_segment/4" do
    test "creates a saved segment", %{user: user, site: site} do
      filters = [%{"field" => "browser", "op" => "is", "value" => "Chrome"}]
      assert {:ok, segment} = Segments.save_segment(user, site, "Chrome users", filters)
      assert segment.name == "Chrome users"
      assert segment.user_id == user.id
      assert segment.site_id == site.id
    end
  end

  describe "list_saved_segments/2" do
    test "returns user's segments for a site", %{user: user, site: site} do
      filters = [%{"field" => "browser", "op" => "is", "value" => "Chrome"}]
      {:ok, _} = Segments.save_segment(user, site, "Chrome users", filters)

      {:ok, _} =
        Segments.save_segment(user, site, "US visitors", [
          %{"field" => "ip_country", "op" => "is", "value" => "US"}
        ])

      segments = Segments.list_saved_segments(user, site)
      assert length(segments) == 2
      assert Enum.any?(segments, &(&1.name == "Chrome users"))
      assert Enum.any?(segments, &(&1.name == "US visitors"))
    end

    test "does not return other user's segments", %{
      user: user,
      other_user: other_user,
      site: site
    } do
      {:ok, _} =
        Segments.save_segment(user, site, "My segment", [
          %{"field" => "browser", "op" => "is", "value" => "Chrome"}
        ])

      assert Segments.list_saved_segments(other_user, site) == []
    end
  end

  describe "delete_segment/2" do
    test "deletes segment owned by user", %{user: user, site: site} do
      {:ok, segment} =
        Segments.save_segment(user, site, "To delete", [
          %{"field" => "browser", "op" => "is", "value" => "Firefox"}
        ])

      assert {:ok, _} = Segments.delete_segment(user, segment.id)
      assert Segments.list_saved_segments(user, site) == []
    end

    test "rejects deletion by non-owner", %{user: user, other_user: other_user, site: site} do
      {:ok, segment} =
        Segments.save_segment(user, site, "Protected", [
          %{"field" => "browser", "op" => "is", "value" => "Safari"}
        ])

      assert {:error, :unauthorized} = Segments.delete_segment(other_user, segment.id)
      assert length(Segments.list_saved_segments(user, site)) == 1
    end

    test "returns error for non-existent segment", %{user: user} do
      assert {:error, :not_found} = Segments.delete_segment(user, 999_999)
    end
  end
end
