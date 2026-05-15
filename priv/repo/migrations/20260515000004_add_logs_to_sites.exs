defmodule Spectabas.Repo.Migrations.AddLogsToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      # Per-site bearer token for the POST /c/logs endpoint. Distinct
      # from public_key (which is for the JS tracker, viewable in
      # source) because logs may contain PII — token is admin-only
      # and shown masked in Site Settings.
      add :logs_token, :string, size: 64
      # Days of log retention. CH-side TTL is fixed at 30d max; query
      # time clamps to this per-site value. 1..30 range, default 14.
      add :logs_retention_days, :integer, default: 14, null: false
      add :logs_enabled, :boolean, default: false, null: false
    end

    create unique_index(:sites, [:logs_token])
  end
end
