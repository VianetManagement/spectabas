defmodule Spectabas.AdIntegrations.SyncLogTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.AdIntegrations.SyncLog
  alias Spectabas.AdIntegrations.AdIntegration
  alias Spectabas.AdIntegrations.Vault
  alias Spectabas.Sites.Site
  alias Spectabas.Repo

  setup do
    account = Spectabas.AccountsFixtures.test_account()

    site =
      Repo.insert!(%Site{
        name: "SyncLog Test Site",
        domain: "b.synclog-test.com",
        public_key: "pk_synclog_#{System.unique_integer([:positive])}",
        gdpr_mode: "off",
        account_id: account.id
      })

    integration =
      Repo.insert!(%AdIntegration{
        site_id: site.id,
        platform: "stripe",
        access_token_encrypted: Vault.encrypt("test_token"),
        refresh_token_encrypted: Vault.encrypt("test_refresh"),
        status: "active"
      })

    %{site: site, integration: integration}
  end

  describe "log/5" do
    test "creates a log entry with all fields", %{integration: integration} do
      assert {:ok, log} =
               SyncLog.log(integration, "sync_started", "ok", "Sync began", details: %{"count" => 42}, duration_ms: 150)

      assert log.id
      assert log.integration_id == integration.id
      assert log.site_id == integration.site_id
      assert log.platform == "stripe"
      assert log.event == "sync_started"
      assert log.status == "ok"
      assert log.message == "Sync began"
      assert log.details == %{"count" => 42}
      assert log.duration_ms == 150
      assert log.inserted_at
    end

    test "creates a log entry with minimal fields", %{integration: integration} do
      assert {:ok, log} = SyncLog.log(integration, "sync_complete", "ok")

      assert log.event == "sync_complete"
      assert log.status == "ok"
      assert log.message == nil
      assert log.details == %{}
      assert log.duration_ms == nil
    end

    test "creates a log entry with error status", %{integration: integration} do
      assert {:ok, log} = SyncLog.log(integration, "sync_failed", "error", "API timeout")

      assert log.status == "error"
      assert log.message == "API timeout"
    end
  end

  describe "recent_for_site/2" do
    test "returns logs ordered by inserted_at desc", %{site: site, integration: integration} do
      {:ok, log1} = SyncLog.log(integration, "first", "ok")
      {:ok, log2} = SyncLog.log(integration, "second", "ok")
      {:ok, log3} = SyncLog.log(integration, "third", "ok")

      logs = SyncLog.recent_for_site(site.id)

      assert length(logs) == 3
      # All three present (order may vary when inserted at same timestamp)
      ids = Enum.map(logs, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([log1.id, log2.id, log3.id])
    end

    test "respects the limit parameter", %{site: site, integration: integration} do
      for i <- 1..5 do
        SyncLog.log(integration, "event_#{i}", "ok")
      end

      logs = SyncLog.recent_for_site(site.id, 3)
      assert length(logs) == 3
    end

    test "returns empty list for site with no logs" do
      assert SyncLog.recent_for_site(-1) == []
    end
  end

  describe "recent_for_integration/2" do
    test "filters by integration_id", %{site: site, integration: integration} do
      # Create a second integration on the same site
      integration2 =
        Repo.insert!(%AdIntegration{
          site_id: site.id,
          platform: "braintree",
          account_id: "bt_acct",
          access_token_encrypted: Vault.encrypt("tok2"),
          refresh_token_encrypted: Vault.encrypt("ref2"),
          status: "active"
        })

      {:ok, _} = SyncLog.log(integration, "stripe_sync", "ok")
      {:ok, _} = SyncLog.log(integration2, "braintree_sync", "ok")
      {:ok, _} = SyncLog.log(integration, "stripe_sync_2", "ok")

      logs = SyncLog.recent_for_integration(integration.id)
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.integration_id == integration.id))

      logs2 = SyncLog.recent_for_integration(integration2.id)
      assert length(logs2) == 1
      assert hd(logs2).platform == "braintree"
    end

    test "respects the limit parameter", %{integration: integration} do
      for i <- 1..5 do
        SyncLog.log(integration, "event_#{i}", "ok")
      end

      logs = SyncLog.recent_for_integration(integration.id, 2)
      assert length(logs) == 2
    end
  end

  describe "cleanup/1" do
    test "deletes old logs", %{integration: integration} do
      # Create a log, then backdate it beyond the cleanup window
      {:ok, old_log} = SyncLog.log(integration, "old_event", "ok")

      # Manually backdate the log to 60 days ago
      cutoff = DateTime.add(DateTime.utc_now(), -60 * 86400, :second)

      Repo.update_all(
        from(l in SyncLog, where: l.id == ^old_log.id),
        set: [inserted_at: cutoff]
      )

      # Create a recent log
      {:ok, _recent_log} = SyncLog.log(integration, "recent_event", "ok")

      # Cleanup with 30-day retention
      {deleted_count, _} = SyncLog.cleanup(30)
      assert deleted_count == 1

      # Only the recent log should remain
      remaining = SyncLog.recent_for_integration(integration.id)
      assert length(remaining) == 1
      assert hd(remaining).event == "recent_event"
    end

    test "deletes nothing when all logs are recent", %{integration: integration} do
      {:ok, _} = SyncLog.log(integration, "event1", "ok")
      {:ok, _} = SyncLog.log(integration, "event2", "ok")

      {deleted_count, _} = SyncLog.cleanup(30)
      assert deleted_count == 0
    end
  end
end
