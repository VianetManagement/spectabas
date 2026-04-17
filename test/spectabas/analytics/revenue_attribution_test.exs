defmodule Spectabas.Analytics.RevenueAttributionTest do
  @moduledoc """
  Integration test for revenue_by_source with all three touch models.

  Inserts synthetic events + ecommerce data into ClickHouse and asserts
  that any/first/last touch all return non-zero revenue with the correct
  source attribution.

  Excluded from default test run. To run:

      mix test --only integration

  Requires a working ClickHouse connection.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Spectabas.ClickHouse
  alias Spectabas.Analytics

  @site_id 999_998
  @visitor_a "v-attrib-a"
  @visitor_b "v-attrib-b"

  # Visitor A: arrives from google.com, then later from facebook.com, then buys
  # Visitor B: arrives from newsletter (utm_source), buys

  setup do
    if !clickhouse_reachable?() do
      flunk("ClickHouse not reachable")
    end

    cleanup()
    insert_test_data()
    on_exit(&cleanup/0)
    :ok
  end

  describe "revenue_by_source touch models" do
    test "any touch returns revenue attributed to all sources" do
      {:ok, rows} = query_attribution("any")

      assert length(rows) > 0, "any touch returned 0 rows"
      total = sum_revenue(rows)
      assert total > 0, "any touch has 0 total revenue"

      # Visitor A touched google + facebook; both should appear
      sources = Enum.map(rows, & &1["source"])
      assert "google.com" in sources, "google.com missing from any touch"
    end

    test "first touch returns revenue attributed to earliest source" do
      {:ok, rows} = query_attribution("first")

      assert length(rows) > 0, "first touch returned 0 rows"
      total = sum_revenue(rows)
      assert total > 0, "first touch has 0 total revenue, rows: #{inspect(rows)}"

      # Visitor A's first source was google.com (timestamp 12:00)
      google = Enum.find(rows, &(&1["source"] == "google.com"))
      assert google, "google.com missing from first touch"
      assert to_float(google["total_revenue"]) > 0
    end

    test "last touch returns revenue attributed to latest source" do
      {:ok, rows} = query_attribution("last")

      assert length(rows) > 0, "last touch returned 0 rows"
      total = sum_revenue(rows)
      assert total > 0, "last touch has 0 total revenue, rows: #{inspect(rows)}"

      # Visitor A's last source was facebook.com (timestamp 14:00)
      facebook = Enum.find(rows, &(&1["source"] == "facebook.com"))
      assert facebook, "facebook.com missing from last touch"
      assert to_float(facebook["total_revenue"]) > 0
    end

    test "total revenue is consistent across all models" do
      {:ok, any_rows} = query_attribution("any")
      {:ok, first_rows} = query_attribution("first")
      {:ok, last_rows} = query_attribution("last")

      # Any touch may have higher total (multi-attribution), but first/last
      # should have the same total (each visitor credited once).
      first_total = sum_revenue(first_rows)
      last_total = sum_revenue(last_rows)

      assert first_total == last_total,
             "first (#{first_total}) and last (#{last_total}) totals should match"

      any_total = sum_revenue(any_rows)

      assert any_total >= first_total,
             "any touch (#{any_total}) should be >= first touch (#{first_total})"
    end
  end

  # --- helpers ---

  defp query_attribution(touch) do
    site = %Spectabas.Sites.Site{id: @site_id, domain: "b.test-attrib.com"}
    user = %Spectabas.Accounts.User{id: 1, role: :platform_admin}

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from = DateTime.add(now, -7, :day)

    Analytics.revenue_by_source(site, user, %{from: from, to: now},
      group_by: "source",
      touch: touch
    )
  end

  defp insert_test_data do
    today = Date.utc_today() |> Date.to_iso8601()

    events = [
      # Visitor A: first touch google.com at 12:00
      %{
        site_id: @site_id,
        visitor_id: @visitor_a,
        session_id: "s-a1",
        event_type: "pageview",
        url_path: "/listings/dog-1",
        referrer_domain: "google.com",
        utm_source: "",
        utm_medium: "",
        utm_campaign: "",
        click_id: "",
        click_id_type: "",
        ip_is_bot: 0,
        timestamp: "#{today} 12:00:00"
      },
      # Visitor A: last touch facebook.com at 14:00
      %{
        site_id: @site_id,
        visitor_id: @visitor_a,
        session_id: "s-a2",
        event_type: "pageview",
        url_path: "/listings/dog-2",
        referrer_domain: "facebook.com",
        utm_source: "",
        utm_medium: "",
        utm_campaign: "",
        click_id: "",
        click_id_type: "",
        ip_is_bot: 0,
        timestamp: "#{today} 14:00:00"
      },
      # Visitor B: only source is newsletter
      %{
        site_id: @site_id,
        visitor_id: @visitor_b,
        session_id: "s-b1",
        event_type: "pageview",
        url_path: "/listings/dog-3",
        referrer_domain: "",
        utm_source: "newsletter",
        utm_medium: "email",
        utm_campaign: "weekly",
        click_id: "",
        click_id_type: "",
        ip_is_bot: 0,
        timestamp: "#{today} 13:00:00"
      }
    ]

    ecommerce = [
      %{
        site_id: @site_id,
        visitor_id: @visitor_a,
        session_id: "s-a2",
        order_id: "order-a1",
        revenue: 99.99,
        timestamp: "#{today} 14:30:00"
      },
      %{
        site_id: @site_id,
        visitor_id: @visitor_b,
        session_id: "s-b1",
        order_id: "order-b1",
        revenue: 49.99,
        timestamp: "#{today} 13:30:00"
      }
    ]

    assert :ok = ClickHouse.insert("events", events)
    assert :ok = ClickHouse.insert("ecommerce_events", ecommerce)
    ClickHouse.execute("OPTIMIZE TABLE events")
    ClickHouse.execute("OPTIMIZE TABLE ecommerce_events")
  end

  defp cleanup do
    for table <- ~w(events ecommerce_events) do
      ClickHouse.execute(
        "ALTER TABLE #{table} DELETE WHERE site_id = #{@site_id} SETTINGS mutations_sync = 2"
      )
    end

    :ok
  end

  defp clickhouse_reachable? do
    case ClickHouse.query("SELECT 1 AS ok") do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp sum_revenue(rows) do
    Enum.reduce(rows, 0.0, fn r, acc -> acc + to_float(r["total_revenue"]) end)
  end

  defp to_float(n) when is_float(n), do: n

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
