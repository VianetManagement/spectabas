defmodule Spectabas.Repo.Migrations.CreateScraperLabels do
  use Ecto.Migration

  def change do
    create table(:scraper_labels) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :visitor_id, :binary_id, null: true
      add :label, :string, size: 20, null: false
      add :source, :string, size: 40, null: false
      add :source_weight, :decimal, precision: 3, scale: 2, null: false
      add :score, :integer, null: true
      add :tier, :string, size: 20, null: true
      add :signals, :map, null: false, default: %{}
      add :email, :string, null: true
      add :user_id, references(:users, on_delete: :nilify_all), null: true
      add :notes, :text, null: true
      add :labeled_at, :utc_datetime, null: false

      timestamps(updated_at: false)
    end

    create index(:scraper_labels, [:site_id, :labeled_at])
    create index(:scraper_labels, [:visitor_id])
    create index(:scraper_labels, [:label, :source])
  end
end
