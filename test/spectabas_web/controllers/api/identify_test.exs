defmodule SpectabasWeb.API.IdentifyTest do
  use SpectabasWeb.ConnCase

  alias Spectabas.{Repo, Sites, APIKeys}
  alias Spectabas.Visitors.Visitor
  import Ecto.Query

  setup %{conn: conn} do
    user = Spectabas.AccountsFixtures.user_fixture()

    # Make user an admin so they can access all sites
    Repo.update_all(from(u in Spectabas.Accounts.User, where: u.id == ^user.id),
      set: [role: :admin]
    )

    user = Spectabas.Accounts.get_user!(user.id)

    # Create a site via the context (auto-generates public_key)
    {:ok, site} =
      Sites.create_site(%{
        name: "Test Site",
        domain: "b.test.com",
        gdpr_mode: "off",
        account_id: Spectabas.AccountsFixtures.test_account().id
      })

    # Create an API key
    {:ok, plaintext, _api_key} = APIKeys.generate(user, "test key")

    # Create a visitor with a known cookie_id
    {:ok, visitor} =
      %Visitor{}
      |> Visitor.changeset(%{
        site_id: site.id,
        cookie_id: "test_cookie_abc123",
        gdpr_mode: "off",
        first_seen_at: DateTime.utc_now() |> DateTime.truncate(:second),
        last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, site: site, visitor: visitor, user: user, api_key: plaintext}
  end

  describe "POST /api/v1/sites/:site_id/identify" do
    test "successfully identifies a visitor by cookie_id with email", %{
      conn: conn,
      site: site,
      visitor: visitor
    } do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "email" => "alice@example.com"
        })

      assert %{"ok" => true, "visitor_id" => vid, "email_hash" => hash} = json_response(conn, 200)
      assert vid == visitor.id
      assert is_binary(hash)
      assert String.length(hash) > 0

      # Verify the email was stored
      updated = Repo.get!(Visitor, visitor.id)
      assert updated.email == "alice@example.com"
      assert updated.email_hash == hash
    end

    test "successfully identifies a visitor with user_id", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "user_id" => "user_42"
        })

      assert %{"ok" => true} = json_response(conn, 200)

      updated =
        Repo.get!(
          Visitor,
          Repo.one!(from(v in Visitor, where: v.cookie_id == "test_cookie_abc123")).id
        )

      assert updated.user_id == "user_42"
    end

    test "successfully identifies with both email and user_id", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "email" => "bob@example.com",
          "user_id" => "user_99"
        })

      assert %{"ok" => true} = json_response(conn, 200)

      updated = Repo.one!(from(v in Visitor, where: v.cookie_id == "test_cookie_abc123"))
      assert updated.email == "bob@example.com"
      assert updated.user_id == "user_99"
    end

    test "returns 200 with matched: false for unknown visitor_id", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "nonexistent_cookie",
          "email" => "nobody@example.com"
        })

      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["matched"] == false
      assert resp["reason"] == "visitor not found"
    end

    test "returns 400 when visitor_id is missing", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "email" => "alice@example.com"
        })

      assert %{"error" => "visitor_id required"} = json_response(conn, 400)
    end

    test "returns 400 when visitor_id is empty", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "",
          "email" => "alice@example.com"
        })

      assert %{"error" => "visitor_id required"} = json_response(conn, 400)
    end

    test "returns 401 without API key", %{site: site} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "email" => "alice@example.com"
        })

      assert json_response(conn, 401)
    end

    test "returns 404 for wrong site_id", %{conn: conn} do
      conn =
        post(conn, "/api/v1/sites/999999/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "email" => "alice@example.com"
        })

      assert %{"error" => _} = json_response(conn, 404)
    end

    test "visitor on different site is not found", %{conn: conn, visitor: _visitor} do
      # Create a different site
      {:ok, other_site} =
        Sites.create_site(%{
          name: "Other Site",
          domain: "b.other.com",
          gdpr_mode: "off",
          account_id: Spectabas.AccountsFixtures.test_account().id
        })

      conn =
        post(conn, "/api/v1/sites/#{other_site.id}/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "email" => "alice@example.com"
        })

      # Visitor belongs to different site — returns 200 with matched: false
      resp = json_response(conn, 200)
      assert resp["ok"] == true
      assert resp["matched"] == false
    end

    test "email is stored as SHA-256 hash", %{conn: conn, site: site, visitor: visitor} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "email" => "Alice@Example.COM"
        })

      assert %{"ok" => true, "email_hash" => hash} = json_response(conn, 200)

      # Hash should be of the lowercase trimmed email
      expected_hash =
        :crypto.hash(:sha256, "alice@example.com")
        |> Base.hex_encode32(case: :lower, padding: false)

      updated = Repo.get!(Visitor, visitor.id)
      assert updated.email_hash == expected_hash
      assert updated.email == "alice@example.com"
    end

    test "ip parameter updates visitor known_ips", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test_cookie_abc123",
          "email" => "alice@example.com",
          "ip" => "203.0.113.42"
        })

      assert %{"ok" => true} = json_response(conn, 200)

      updated = Repo.one!(from(v in Visitor, where: v.cookie_id == "test_cookie_abc123"))
      assert updated.last_ip == "203.0.113.42"
    end
  end
end
