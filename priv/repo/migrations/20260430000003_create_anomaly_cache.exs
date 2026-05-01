defmodule Spectabas.Repo.Migrations.CreateAnomalyCache do
  use Ecto.Migration

  def change do
    create table(:anomaly_cache) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :anomalies, :map, null: false, default: %{}
      add :generated_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:anomaly_cache, [:site_id])
  end
end
