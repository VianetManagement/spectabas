defmodule Spectabas.Repo.Migrations.AddScraperWhitelistedToVisitors do
  use Ecto.Migration

  def change do
    alter table(:visitors) do
      add :scraper_whitelisted, :boolean, default: false, null: false
    end

    create index(:visitors, [:scraper_whitelisted], where: "scraper_whitelisted = true")
  end
end
