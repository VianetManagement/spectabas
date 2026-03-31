defmodule SpectabasWeb.API.ApiSecurityTest do
  use SpectabasWeb.ConnCase

  alias Spectabas.{Repo, Sites, APIKeys}
  alias Spectabas.Accounts.APIKey
  import Ecto.Query

  setup %{conn: conn} do
    user = Spectabas.AccountsFixtures.user_fixture()

    Repo.update_all(from(u in Spectabas.Accounts.User, where: u.id == ^user.id),
      set: [role: :admin]
    )

    user = Spectabas.Accounts.get_user!(user.id)

    {:ok, site} =
      Sites.create_site(%{name: "Security Test", domain: "b.sec-test.com", gdpr_mode: "off"})

    {:ok, site2} =
      Sites.create_site(%{name: "Other Site", domain: "b.other-sec.com", gdpr_mode: "off"})

    %{conn: conn, user: user, site: site, site2: site2}
  end

  describe "scope enforcement" do
    test "token with read:stats can access stats endpoint", %{conn: conn, user: user, site: site} do
      {:ok, key, _} = APIKeys.generate(user, "read-only", scopes: ["read:stats"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site.id}/stats")

      # 200 or 500 (CH down) — not 403
      assert conn.status in [200, 500]
    end

    test "token without read:stats cannot access stats endpoint", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, key, _} = APIKeys.generate(user, "write-only", scopes: ["write:events"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site.id}/stats")

      assert %{"error" => "insufficient scope"} = json_response(conn, 403)
    end

    test "token with write:identify can identify visitors", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, key, _} = APIKeys.generate(user, "identify-only", scopes: ["write:identify"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test",
          "email" => "test@test.com"
        })

      # 404 (visitor not found) is fine — means scope check passed
      assert conn.status in [200, 404]
    end

    test "token without write:identify cannot identify visitors", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, key, _} = APIKeys.generate(user, "read-only", scopes: ["read:stats"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sites/#{site.id}/identify", %{
          "visitor_id" => "test",
          "email" => "test@test.com"
        })

      assert %{"error" => "insufficient scope"} = json_response(conn, 403)
    end

    test "token with write:events can record transactions", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, key, _} = APIKeys.generate(user, "write-events", scopes: ["write:events"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "SCOPE-TEST",
          "revenue" => 10.0
        })

      # 200 or 500 (CH down) — not 403
      assert conn.status in [200, 500]
    end

    test "token without write:events cannot record transactions", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, key, _} = APIKeys.generate(user, "read-only", scopes: ["read:stats"])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "SCOPE-FAIL",
          "revenue" => 10.0
        })

      assert %{"error" => "insufficient scope"} = json_response(conn, 403)
    end
  end

  describe "site restriction" do
    test "token restricted to site1 can access site1", %{
      conn: conn,
      user: user,
      site: site
    } do
      {:ok, key, _} = APIKeys.generate(user, "site-restricted", site_ids: [site.id])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site.id}/stats")

      assert conn.status in [200, 500]
    end

    test "token restricted to site1 cannot access site2", %{
      conn: conn,
      user: user,
      site2: site2
    } do
      # Restrict to a different site ID
      {:ok, key, _} = APIKeys.generate(user, "site-restricted", site_ids: [999])

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site2.id}/stats")

      assert conn.status in [403, 404]
    end

    test "token with empty site_ids can access any site", %{
      conn: conn,
      user: user,
      site: site,
      site2: site2
    } do
      {:ok, key, _} = APIKeys.generate(user, "all-sites")

      conn1 =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site.id}/stats")

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site2.id}/stats")

      assert conn1.status in [200, 500]
      assert conn2.status in [200, 500]
    end
  end

  describe "token expiry" do
    test "expired token is rejected", %{conn: conn, user: user, site: site} do
      yesterday = DateTime.add(DateTime.utc_now(), -86400, :second)
      {:ok, key, _} = APIKeys.generate(user, "expired", expires_at: yesterday)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site.id}/stats")

      assert %{"error" => "api key expired"} = json_response(conn, 403)
    end

    test "non-expired token works", %{conn: conn, user: user, site: site} do
      tomorrow = DateTime.add(DateTime.utc_now(), 86400, :second)
      {:ok, key, _} = APIKeys.generate(user, "valid", expires_at: tomorrow)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site.id}/stats")

      assert conn.status in [200, 500]
    end

    test "token without expiry works", %{conn: conn, user: user, site: site} do
      {:ok, key, _} = APIKeys.generate(user, "no-expiry")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{key}")
        |> get("/api/v1/sites/#{site.id}/stats")

      assert conn.status in [200, 500]
    end
  end

  describe "API access logging" do
    test "API call creates an access log entry", %{conn: conn, user: user, site: site} do
      {:ok, key, api_key} = APIKeys.generate(user, "logging-test")

      initial_count = Repo.aggregate(Spectabas.Accounts.ApiAccessLog, :count, :id)

      conn
      |> put_req_header("authorization", "Bearer #{key}")
      |> get("/api/v1/sites/#{site.id}/stats")

      # Give the async Task a moment to write
      Process.sleep(100)

      new_count = Repo.aggregate(Spectabas.Accounts.ApiAccessLog, :count, :id)
      assert new_count > initial_count

      log =
        Repo.one(
          from(l in Spectabas.Accounts.ApiAccessLog,
            where: l.api_key_id == ^api_key.id,
            order_by: [desc: l.id],
            limit: 1
          )
        )

      assert log.method == "GET"
      assert log.path == "/api/v1/sites/#{site.id}/stats"
      assert log.key_prefix == api_key.key_prefix
      assert log.user_id == user.id
    end
  end

  describe "valid scopes" do
    test "creating a key with invalid scopes fails", %{user: user} do
      result = APIKeys.generate(user, "bad-scopes", scopes: ["read:stats", "hack:everything"])
      assert {:error, changeset} = result
      assert %{scopes: _} = errors_on(changeset)
    end

    test "creating a key with valid scopes succeeds", %{user: user} do
      {:ok, _key, api_key} =
        APIKeys.generate(user, "good-scopes", scopes: ["read:stats", "write:events"])

      assert api_key.scopes == ["read:stats", "write:events"]
    end

    test "default scopes include read and write but not admin", %{user: user} do
      {:ok, _key, api_key} = APIKeys.generate(user, "defaults")
      assert "read:stats" in api_key.scopes
      assert "write:events" in api_key.scopes
      refute "admin:sites" in api_key.scopes
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
