defmodule Spectabas.InsightsTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.{Insights, Repo, Sites}

  defp build_site! do
    Repo.insert!(%Sites.Site{
      name: "Test Site #{System.unique_integer([:positive])}",
      domain: "b.t-#{System.unique_integer([:positive])}.com",
      public_key: "k_#{System.unique_integer([:positive])}",
      active: true,
      gdpr_mode: "off",
      account_id: Spectabas.AccountsFixtures.test_account().id
    })
  end

  defp build_user! do
    Spectabas.AccountsFixtures.user_fixture()
  end

  describe "create/1" do
    test "inserts an insight with a dedupe_key" do
      site = build_site!()

      attrs = %{
        site_id: site.id,
        kind: "anomaly_spike",
        severity: "warning",
        title: "Pageviews spiked 50%",
        body: "Traffic doubled this week.",
        dedupe_key: Insights.dedupe_key("anomaly", %{"metric" => "pageviews"})
      }

      assert {:ok, insight} = Insights.create(attrs)
      assert insight.title == "Pageviews spiked 50%"
      assert insight.severity == "warning"
    end

    test "is idempotent on (site, kind, dedupe_key)" do
      site = build_site!()
      key = Insights.dedupe_key("anomaly", %{"metric" => "pageviews"})

      base = %{
        site_id: site.id,
        kind: "anomaly_spike",
        title: "First",
        body: "v1",
        dedupe_key: key
      }

      {:ok, first} = Insights.create(base)
      {:ok, second} = Insights.create(Map.put(base, :title, "Second"))

      assert first.id == second.id
      assert second.title == "Second"
    end
  end

  describe "dismiss/2 + list_active_for_user/2" do
    test "dismissed insights drop out of the active list for the dismissing user" do
      site = build_site!()
      user_a = build_user!()
      user_b = build_user!()

      {:ok, insight} =
        Insights.create(%{
          site_id: site.id,
          kind: "goal_pace",
          title: "Goal X moved",
          dedupe_key: "x"
        })

      assert Enum.any?(Insights.list_active_for_user(site.id, user_a.id), &(&1.id == insight.id))

      Insights.dismiss(insight.id, user_a.id)

      refute Enum.any?(Insights.list_active_for_user(site.id, user_a.id), &(&1.id == insight.id))
      assert Enum.any?(Insights.list_active_for_user(site.id, user_b.id), &(&1.id == insight.id))
    end

    test "dismiss is idempotent" do
      site = build_site!()
      user = build_user!()

      {:ok, insight} =
        Insights.create(%{
          site_id: site.id,
          kind: "goal_pace",
          title: "Goal X",
          dedupe_key: "y"
        })

      assert {:ok, _} = Insights.dismiss(insight.id, user.id)
      assert {:ok, _} = Insights.dismiss(insight.id, user.id)
    end
  end

  describe "set_explanation/2" do
    test "writes the AI-generated explanation field" do
      site = build_site!()

      {:ok, insight} =
        Insights.create(%{
          site_id: site.id,
          kind: "anomaly_spike",
          title: "X",
          dedupe_key: "z"
        })

      assert is_nil(insight.explanation)

      assert {:ok, updated} = Insights.set_explanation(insight, "Traffic doubled because…")
      assert updated.explanation == "Traffic doubled because…"
    end
  end
end
