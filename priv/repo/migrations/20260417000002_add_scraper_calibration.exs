defmodule Spectabas.Repo.Migrations.AddScraperCalibration do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :scraper_weight_overrides, :map
    end

    create table(:scraper_calibrations) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :baseline, :map
      add :recommendations, :map
      add :ai_provider, :string
      add :ai_model, :string
      add :prompt_tokens, :integer
      add :completion_tokens, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:scraper_calibrations, [:site_id, :inserted_at])
  end
end
