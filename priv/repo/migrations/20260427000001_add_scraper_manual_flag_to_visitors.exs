defmodule Spectabas.Repo.Migrations.AddScraperManualFlagToVisitors do
  use Ecto.Migration

  def change do
    alter table(:visitors) do
      add :scraper_manual_flag, :boolean, default: false, null: false
    end

    create index(:visitors, [:scraper_manual_flag], where: "scraper_manual_flag = true")
  end
end
