defmodule Spectabas.Reports.EmailReportTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.Reports

  describe "period_key/2" do
    test "daily key is ISO date" do
      {:ok, dt} = DateTime.new(~D[2026-03-28], ~T[14:30:00], "Etc/UTC")
      assert Reports.period_key(:daily, dt) == "2026-03-28"
    end

    test "weekly key is ISO year-week" do
      {:ok, dt} = DateTime.new(~D[2026-03-28], ~T[14:30:00], "Etc/UTC")
      key = Reports.period_key(:weekly, dt)
      assert key =~ ~r/^\d{4}-W\d{2}$/
    end

    test "monthly key is year-month" do
      {:ok, dt} = DateTime.new(~D[2026-03-28], ~T[14:30:00], "Etc/UTC")
      assert Reports.period_key(:monthly, dt) == "2026-03"
    end

    test "monthly key pads single-digit months" do
      {:ok, dt} = DateTime.new(~D[2026-01-05], ~T[09:00:00], "Etc/UTC")
      assert Reports.period_key(:monthly, dt) == "2026-01"
    end

    test "unknown frequency returns nil" do
      {:ok, dt} = DateTime.new(~D[2026-03-28], ~T[14:30:00], "Etc/UTC")
      assert Reports.period_key(:unknown, dt) == nil
    end
  end

  describe "upsert_email_subscription/3" do
    import Spectabas.AccountsFixtures

    test "creates new subscription" do
      user = user_fixture()

      site =
        Spectabas.Repo.insert!(%Spectabas.Sites.Site{
          name: "Test",
          domain: "b.test.com",
          public_key: "test_#{System.unique_integer([:positive])}",
          active: true
        })

      assert {:ok, sub} =
               Reports.upsert_email_subscription(user, site, %{
                 "frequency" => "weekly",
                 "send_hour" => "9"
               })

      assert sub.frequency == :weekly
      assert sub.send_hour == 9
    end

    test "updates existing subscription" do
      user = user_fixture()

      site =
        Spectabas.Repo.insert!(%Spectabas.Sites.Site{
          name: "Test",
          domain: "b.test2.com",
          public_key: "test2_#{System.unique_integer([:positive])}",
          active: true
        })

      {:ok, _} =
        Reports.upsert_email_subscription(user, site, %{
          "frequency" => "weekly",
          "send_hour" => "9"
        })

      {:ok, updated} =
        Reports.upsert_email_subscription(user, site, %{
          "frequency" => "daily",
          "send_hour" => "14"
        })

      assert updated.frequency == :daily
      assert updated.send_hour == 14
    end

    test "get returns nil for non-existent subscription" do
      user = user_fixture()

      site =
        Spectabas.Repo.insert!(%Spectabas.Sites.Site{
          name: "Test",
          domain: "b.test3.com",
          public_key: "test3_#{System.unique_integer([:positive])}",
          active: true
        })

      assert Reports.get_email_subscription(user, site) == nil
    end
  end

  describe "unsubscribe/1" do
    import Spectabas.AccountsFixtures

    test "sets frequency to off" do
      user = user_fixture()

      site =
        Spectabas.Repo.insert!(%Spectabas.Sites.Site{
          name: "Test",
          domain: "b.test4.com",
          public_key: "test4_#{System.unique_integer([:positive])}",
          active: true
        })

      {:ok, sub} =
        Reports.upsert_email_subscription(user, site, %{
          "frequency" => "weekly",
          "send_hour" => "9"
        })

      {:ok, unsubbed} = Reports.unsubscribe(sub.id)
      assert unsubbed.frequency == :off
    end

    test "returns error for non-existent subscription" do
      assert {:error, :not_found} = Reports.unsubscribe(999_999)
    end
  end
end
