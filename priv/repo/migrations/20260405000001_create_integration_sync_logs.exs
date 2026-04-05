defmodule Spectabas.Repo.Migrations.CreateIntegrationSyncLogs do
  use Ecto.Migration

  def change do
    create table(:integration_sync_logs) do
      add :integration_id, references(:ad_integrations, on_delete: :delete_all), null: false
      add :site_id, :bigint, null: false
      add :platform, :string, null: false
      add :event, :string, null: false
      add :status, :string, null: false, default: "ok"
      add :message, :text
      add :details, :map, default: %{}
      add :duration_ms, :integer

      timestamps(updated_at: false)
    end

    create index(:integration_sync_logs, [:integration_id])
    create index(:integration_sync_logs, [:site_id, :inserted_at])
    create index(:integration_sync_logs, [:inserted_at])
  end
end
