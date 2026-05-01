defmodule Spectabas.Repo.Migrations.CreateConversionActions do
  use Ecto.Migration

  def change do
    create table(:conversion_actions) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :name, :string, null: false
      # signup | listing | purchase | custom
      add :kind, :string, null: false
      # url_pattern | click_element | stripe_payment | custom_event
      add :detection_type, :string, null: false
      # JSON: %{"url_pattern" => "/welcome*"} or %{"selector" => "#publish-btn"}
      add :detection_config, :map, null: false, default: %{}
      # count_only | from_payment | fixed
      add :value_strategy, :string, null: false, default: "count_only"
      add :fixed_value, :decimal, precision: 12, scale: 2
      # Default per Google docs.
      add :attribution_window_days, :integer, null: false, default: 90
      # first_click | last_click — informational only; Google Ads honors its own
      # conversion-action attribution model. Stored so we know how to resolve
      # the click_id at conversion-record time.
      add :attribution_model, :string, null: false, default: "first_click"

      # Google Ads
      add :google_conversion_action_id, :string
      add :google_account_timezone, :string

      # Microsoft Ads
      add :microsoft_conversion_name, :string

      add :active, :boolean, null: false, default: true

      # Bot/quality filter — skip uploading conversions whose visitor scored
      # this high or higher. Defaults to 40 (the "watching" tier in
      # ScraperDetector). Set 0 to disable.
      add :max_scraper_score, :integer, null: false, default: 40

      timestamps()
    end

    create index(:conversion_actions, [:site_id])
    create index(:conversion_actions, [:site_id, :active])
  end
end
