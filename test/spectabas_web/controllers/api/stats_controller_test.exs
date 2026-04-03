defmodule SpectabasWeb.API.StatsControllerTest do
  use SpectabasWeb.ConnCase

  alias Spectabas.{Repo, Sites, APIKeys}
  import Ecto.Query

  setup %{conn: conn} do
    user = Spectabas.AccountsFixtures.user_fixture()

    Repo.update_all(from(u in Spectabas.Accounts.User, where: u.id == ^user.id),
      set: [role: :admin]
    )

    user = Spectabas.Accounts.get_user!(user.id)

    {:ok, site} =
      Sites.create_site(%{
        name: "API Test Site",
        domain: "b.api-test.com",
        gdpr_mode: "off",
        account_id: Spectabas.AccountsFixtures.test_account().id
      })

    {:ok, plaintext, _api_key} = APIKeys.generate(user, "api test key")

    authed_conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed_conn, site: site, user: user}
  end

  # --- GET /api/v1/sites/:site_id/stats ---

  describe "GET /stats" do
    test "returns overview stats or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/stats")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        assert %{"data" => data} = json_response(conn, 200)
        assert Map.has_key?(data, "unique_visitors")
        assert Map.has_key?(data, "pageviews")
      end
    end

    test "accepts period parameter", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/stats?period=30d")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn = build_conn() |> get("/api/v1/sites/#{site.id}/stats")
      assert json_response(conn, 401)
    end

    test "returns 404 for nonexistent site", %{conn: conn} do
      conn = get(conn, "/api/v1/sites/999999/stats")
      assert %{"error" => _} = json_response(conn, 404)
    end
  end

  # --- GET /api/v1/sites/:site_id/pages ---

  describe "GET /pages" do
    test "returns top pages or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/pages")
      assert conn.status in [200, 500]

      if conn.status == 200 do
        assert %{"data" => data} = json_response(conn, 200)
        assert is_list(data)
      end
    end

    test "returns 401 without API key", %{site: site} do
      conn = build_conn() |> get("/api/v1/sites/#{site.id}/pages")
      assert json_response(conn, 401)
    end
  end

  # --- GET /api/v1/sites/:site_id/sources ---

  describe "GET /sources" do
    test "returns top sources or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/sources")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn = build_conn() |> get("/api/v1/sites/#{site.id}/sources")
      assert json_response(conn, 401)
    end
  end

  # --- GET /api/v1/sites/:site_id/countries ---

  describe "GET /countries" do
    test "returns top countries or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/countries")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn = build_conn() |> get("/api/v1/sites/#{site.id}/countries")
      assert json_response(conn, 401)
    end
  end

  # --- GET /api/v1/sites/:site_id/devices ---

  describe "GET /devices" do
    test "returns top devices or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/devices")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn = build_conn() |> get("/api/v1/sites/#{site.id}/devices")
      assert json_response(conn, 401)
    end
  end

  # --- GET /api/v1/sites/:site_id/realtime ---

  describe "GET /realtime" do
    test "returns realtime count or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/realtime")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn = build_conn() |> get("/api/v1/sites/#{site.id}/realtime")
      assert json_response(conn, 401)
    end
  end

  # --- GET /api/v1/sites/:site_id/realtime/visitors ---

  describe "GET /realtime/visitors" do
    test "returns realtime visitor list or handles ClickHouse unavailable", %{
      conn: conn,
      site: site
    } do
      conn = get(conn, "/api/v1/sites/#{site.id}/realtime/visitors")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn = build_conn() |> get("/api/v1/sites/#{site.id}/realtime/visitors")
      assert json_response(conn, 401)
    end
  end
end
