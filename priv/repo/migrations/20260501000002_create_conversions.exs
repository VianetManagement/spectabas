defmodule Spectabas.Repo.Migrations.CreateConversions do
  use Ecto.Migration

  def change do
    create table(:conversions) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false

      add :conversion_action_id,
          references(:conversion_actions, on_delete: :delete_all),
          null: false

      # Visitor + click attribution snapshot (resolved at detect time).
      # NOT a foreign key — visitors may be cleaned up; we keep the row.
      add :visitor_id, :binary_id
      add :email, :string
      add :click_id, :string
      # google | google_wbraid | google_gbraid | microsoft | meta | other
      add :click_id_type, :string

      # Conversion specifics
      add :occurred_at, :utc_datetime, null: false
      add :value, :decimal, precision: 12, scale: 2, default: 0
      add :currency, :string, size: 3

      # Source pointers — what triggered detection
      # stripe | pageview | click_element | custom_event | manual
      add :detection_source, :string, null: false
      # ch_..., pi_..., or event_id
      add :source_reference, :string

      # Idempotency key — unique within (site_id, conversion_action_id) so we
      # don't double-count. Examples: "stripe:ch_abc", "pageview:visitor_id:date"
      add :dedup_key, :string, null: false

      # Upload tracking
      # pending | skipped_no_click | skipped_quality | uploading
      # | uploaded_google | uploaded_microsoft | uploaded_both | failed
      add :upload_state, :string, null: false, default: "pending"
      add :uploaded_at, :utc_datetime
      add :upload_error, :text

      # Match results (populated once Google reports them)
      add :google_match_status, :string
      add :microsoft_match_status, :string

      add :scraper_score_at_detect, :integer

      timestamps()
    end

    create unique_index(:conversions, [:site_id, :conversion_action_id, :dedup_key],
             name: :conversions_dedup_idx
           )

    create index(:conversions, [:site_id, :upload_state])
    create index(:conversions, [:site_id, :occurred_at])
    create index(:conversions, [:visitor_id])
  end
end
