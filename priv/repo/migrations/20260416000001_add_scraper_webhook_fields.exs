defmodule Spectabas.Repo.Migrations.AddScraperWebhookFields do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :scraper_webhook_url, :string
      add :scraper_webhook_secret, :string
      add :scraper_webhook_enabled, :boolean, default: false, null: false
    end

    alter table(:visitors) do
      add :scraper_webhook_sent_at, :utc_datetime
      add :scraper_webhook_score, :integer
    end
  end
end
