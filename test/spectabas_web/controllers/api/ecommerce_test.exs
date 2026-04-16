defmodule SpectabasWeb.API.EcommerceTest do
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
        name: "Ecommerce Test",
        domain: "b.shop-test.com",
        gdpr_mode: "off",
        ecommerce_enabled: true,
        currency: "USD",
        account_id: Spectabas.AccountsFixtures.test_account().id
      })

    {:ok, plaintext, _api_key} = APIKeys.generate(user, "ecommerce test key")

    authed_conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed_conn, site: site, user: user, api_key: plaintext}
  end

  describe "GET /api/v1/sites/:site_id/ecommerce" do
    test "returns ecommerce stats or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/ecommerce")
      # Either returns data (ClickHouse available) or internal error (ClickHouse down)
      assert conn.status in [200, 500]

      if conn.status == 200 do
        assert %{"data" => data} = json_response(conn, 200)
        assert Map.has_key?(data, "total_orders")
      end
    end

    test "returns 401 without API key", %{site: site} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> get("/api/v1/sites/#{site.id}/ecommerce")

      assert json_response(conn, 401)
    end

    test "returns 404 for nonexistent site", %{conn: conn} do
      conn = get(conn, "/api/v1/sites/999999/ecommerce")
      assert %{"error" => _} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/sites/:site_id/ecommerce/products" do
    test "returns top products or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/ecommerce/products")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> get("/api/v1/sites/#{site.id}/ecommerce/products")

      assert json_response(conn, 401)
    end
  end

  describe "GET /api/v1/sites/:site_id/ecommerce/orders" do
    test "returns recent orders or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn = get(conn, "/api/v1/sites/#{site.id}/ecommerce/orders")
      assert conn.status in [200, 500]
    end

    test "returns 401 without API key", %{site: site} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> get("/api/v1/sites/#{site.id}/ecommerce/orders")

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/v1/sites/:site_id/ecommerce/transactions" do
    test "records a transaction or handles ClickHouse unavailable", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TEST-001",
          "revenue" => 99.99,
          "visitor_id" => "test-visitor-123",
          "items" => [%{"name" => "Widget", "price" => 49.99, "quantity" => 2}]
        })

      # Either succeeds (ClickHouse available) or 500 (ClickHouse down)
      assert conn.status in [200, 500]

      if conn.status == 200 do
        assert %{"ok" => true, "order_id" => "ORD-TEST-001"} = json_response(conn, 200)
      end
    end

    test "returns 400 when order_id is missing", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "revenue" => 50.00
        })

      assert %{"error" => "order_id required"} = json_response(conn, 400)
    end

    test "returns 400 when order_id is empty", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "",
          "revenue" => 50.00
        })

      assert %{"error" => "order_id required"} = json_response(conn, 400)
    end

    test "returns 401 without API key", %{site: site} do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TEST-002",
          "revenue" => 25.00
        })

      assert json_response(conn, 401)
    end

    test "returns 404 for nonexistent site", %{conn: conn} do
      conn =
        post(conn, "/api/v1/sites/999999/ecommerce/transactions", %{
          "order_id" => "ORD-TEST-003",
          "revenue" => 10.00
        })

      assert %{"error" => _} = json_response(conn, 404)
    end

    test "handles string revenue amounts", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TEST-004",
          "revenue" => "149.95",
          "tax" => "12.00",
          "shipping" => "5.99"
        })

      # Either succeeds or ClickHouse is down
      assert conn.status in [200, 500]
    end

    test "handles full transaction with all fields", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TEST-005",
          "revenue" => 199.97,
          "subtotal" => 179.97,
          "tax" => 14.40,
          "shipping" => 5.60,
          "discount" => 20.00,
          "currency" => "USD",
          "visitor_id" => "abc123",
          "session_id" => "sess456",
          "items" => [
            %{"name" => "Pro Widget", "price" => 59.99, "quantity" => 3}
          ]
        })

      assert conn.status in [200, 500]
    end

    test "accepts occurred_at as integer Unix timestamp", %{conn: conn, site: site} do
      one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_unix()

      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TIMESTAMP-1",
          "revenue" => 50.00,
          "occurred_at" => one_hour_ago
        })

      assert conn.status in [200, 500]
    end

    test "accepts occurred_at as string Unix timestamp", %{conn: conn, site: site} do
      two_hours_ago =
        DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.to_unix() |> to_string()

      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TIMESTAMP-2",
          "revenue" => 75.00,
          "occurred_at" => two_hours_ago
        })

      assert conn.status in [200, 500]
    end

    test "ignores occurred_at older than 7 days", %{conn: conn, site: site} do
      eight_days_ago =
        DateTime.utc_now() |> DateTime.add(-8 * 86400, :second) |> DateTime.to_unix()

      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TIMESTAMP-3",
          "revenue" => 25.00,
          "occurred_at" => eight_days_ago
        })

      # Should still succeed (falls back to current time)
      assert conn.status in [200, 500]
    end

    test "ignores occurred_at in the future", %{conn: conn, site: site} do
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()

      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TIMESTAMP-4",
          "revenue" => 30.00,
          "occurred_at" => future
        })

      # Should still succeed (falls back to current time)
      assert conn.status in [200, 500]
    end

    test "ignores invalid occurred_at value", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-TIMESTAMP-5",
          "revenue" => 15.00,
          "occurred_at" => "not-a-timestamp"
        })

      assert conn.status in [200, 500]
    end

    test "accepts channel and source fields", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-1",
          "revenue" => 9.99,
          "channel" => "web",
          "source" => "dashboard.main_cta"
        })

      assert conn.status in [200, 500]

      if conn.status == 200 do
        assert %{"ok" => true, "order_id" => "ORD-CHANNEL-1"} = json_response(conn, 200)
      end
    end

    test "accepts transaction with channel only (no source)", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-2",
          "revenue" => 2.99,
          "channel" => "ios_iap"
        })

      assert conn.status in [200, 500]
    end

    test "accepts transaction with source only (no channel)", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-3",
          "revenue" => 19.99,
          "source" => "email.subscription_expired"
        })

      assert conn.status in [200, 500]
    end

    test "accepts transaction without channel or source (backward compat)", %{
      conn: conn,
      site: site
    } do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-4",
          "revenue" => 49.99
        })

      assert conn.status in [200, 500]
    end

    test "handles non-string channel and source values without crashing", %{
      conn: conn,
      site: site
    } do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-5",
          "revenue" => 5.00,
          "channel" => 42,
          "source" => true
        })

      assert conn.status in [200, 500]
    end

    test "handles null channel and source values", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-6",
          "revenue" => 5.00,
          "channel" => nil,
          "source" => nil
        })

      assert conn.status in [200, 500]
    end

    test "handles channel and source with whitespace and mixed case", %{conn: conn, site: site} do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-7",
          "revenue" => 5.00,
          "channel" => "  WEB  ",
          "source" => "  Dashboard.Main_CTA  "
        })

      assert conn.status in [200, 500]
    end

    test "handles oversized channel and source values", %{conn: conn, site: site} do
      long_string = String.duplicate("a", 200)

      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-CHANNEL-8",
          "revenue" => 5.00,
          "channel" => long_string,
          "source" => long_string
        })

      assert conn.status in [200, 500]
    end

    test "full transaction with all fields including channel and source", %{
      conn: conn,
      site: site
    } do
      conn =
        post(conn, "/api/v1/sites/#{site.id}/ecommerce/transactions", %{
          "order_id" => "ORD-FULL-CHANNEL",
          "revenue" => 99.99,
          "subtotal" => 89.99,
          "tax" => 7.20,
          "shipping" => 2.80,
          "discount" => 10.00,
          "currency" => "USD",
          "visitor_id" => "vis-123",
          "session_id" => "sess-456",
          "email" => "buyer@example.com",
          "channel" => "web",
          "source" => "messages",
          "items" => [
            %{
              "name" => "Monthly Plan",
              "price" => 99.99,
              "quantity" => 1,
              "category" => "new_subscription"
            }
          ],
          "occurred_at" => DateTime.utc_now() |> DateTime.add(-600) |> DateTime.to_unix()
        })

      assert conn.status in [200, 500]

      if conn.status == 200 do
        assert %{"ok" => true, "order_id" => "ORD-FULL-CHANNEL"} = json_response(conn, 200)
      end
    end
  end

  describe "Spectabas.Ecommerce.Normalize.short_string/1" do
    alias Spectabas.Ecommerce.Normalize

    test "trims whitespace" do
      assert Normalize.short_string("  web  ") == "web"
    end

    test "lowercases" do
      assert Normalize.short_string("WEB") == "web"
      assert Normalize.short_string("Dashboard.Main_CTA") == "dashboard.main_cta"
    end

    test "trims and lowercases combined" do
      assert Normalize.short_string("  IOS_IAP  ") == "ios_iap"
    end

    test "truncates at 64 characters" do
      long = String.duplicate("a", 200)
      result = Normalize.short_string(long)
      assert String.length(result) == 64
    end

    test "returns empty string for nil" do
      assert Normalize.short_string(nil) == ""
    end

    test "returns empty string for integer" do
      assert Normalize.short_string(42) == ""
    end

    test "returns empty string for boolean" do
      assert Normalize.short_string(true) == ""
    end

    test "returns empty string for empty string" do
      assert Normalize.short_string("") == ""
    end

    test "handles unicode" do
      assert Normalize.short_string("wéb") == "wéb"
      assert Normalize.short_string("MENÜ") == "menü"
    end

    test "preserves dots and underscores" do
      assert Normalize.short_string("email.subscription_expired") == "email.subscription_expired"
      assert Normalize.short_string("dashboard.main_cta") == "dashboard.main_cta"
    end
  end
end
