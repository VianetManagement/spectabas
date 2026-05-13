defmodule Spectabas.Repo.Migrations.AddScraperLastScanColumns do
  use Ecto.Migration

  def change do
    # Two new columns split from scraper_webhook_score so the worker can
    # always persist the latest computed score without breaking tier-
    # escalation webhook logic (which reads scraper_webhook_score to decide
    # if curr_tier > prev_tier).
    #
    # scraper_webhook_score → "score at last webhook fire" (unchanged semantics)
    # scraper_last_scan_score → "score at the last worker scan" (always-current)
    alter table(:visitors) do
      add :scraper_last_scan_score, :integer
      add :scraper_last_scan_at, :utc_datetime
    end

    create index(:visitors, [:site_id, :scraper_last_scan_score])
  end
end
