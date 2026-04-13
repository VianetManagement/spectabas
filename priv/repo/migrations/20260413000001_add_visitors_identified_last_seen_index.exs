defmodule Spectabas.Repo.Migrations.AddVisitorsIdentifiedLastSeenIndex do
  use Ecto.Migration

  # Drives the "identified users" card on the dashboard. The previous approach
  # (ClickHouse DISTINCT visitor_id → Postgres IN ($1,…,$N)) routinely took
  # 8-9 seconds on 30-day ranges. This partial index turns the replacement
  # query into a simple range scan — microseconds even on large sites.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(
                           :visitors,
                           [:site_id, :last_seen_at],
                           name: "visitors_identified_by_site_last_seen_idx",
                           where: "email IS NOT NULL AND email <> ''",
                           concurrently: true
                         )
  end
end
