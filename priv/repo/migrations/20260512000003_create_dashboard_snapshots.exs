defmodule Spectabas.Repo.Migrations.CreateDashboardSnapshots do
  use Ecto.Migration

  def change do
    create table(:dashboard_snapshots) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :kind, :string, null: false, size: 64
      add :window_days, :integer, null: false
      add :data, :map, null: false, default: "{}"
      add :refreshed_at, :utc_datetime, null: false
    end

    create unique_index(:dashboard_snapshots, [:site_id, :kind])
    create index(:dashboard_snapshots, [:site_id])
  end
end
