defmodule Spectabas.Repo.Migrations.CreatePageAudits do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      # Weekly headless-browser crawl budget for the SEO audit feature.
      # 100..5000 range, default 500. Site admins adjust in Site Settings.
      # On-demand audits don't count against this budget.
      add :seo_crawl_budget, :integer, default: 500, null: false
    end

    create table(:page_audits) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :url, :string, null: false, size: 2048

      # Crawl provenance
      add :captured_at, :utc_datetime_usec, null: false
      add :trigger, :string, null: false, default: "scheduled"
      add :status_code, :integer
      add :final_url, :string, size: 2048
      add :response_time_ms, :integer
      add :content_hash, :string, size: 64

      # Parsed metadata
      add :title, :text
      add :meta_description, :text
      add :h1, :text
      add :h1_count, :integer
      add :canonical, :text
      add :og_title, :text
      add :og_description, :text
      add :og_image, :text
      add :schema_types, {:array, :string}, default: []
      add :meta_robots, :string

      # Content metrics
      add :word_count, :integer
      add :internal_link_count, :integer
      add :external_link_count, :integer
      add :image_count, :integer
      add :image_alt_count, :integer

      # Scoring
      add :score, :integer
      add :issues, :map, default: %{}

      # Network/error context (for failed crawls)
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    # Latest audit per URL is the hot read path; secondary index covers
    # the audit-history view.
    create index(:page_audits, [:site_id, :url, :captured_at])
    create index(:page_audits, [:site_id, :score])
  end
end
