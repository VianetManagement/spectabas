defmodule Spectabas.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :visitor_id, :binary_id, null: false
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :duration_s, :integer, default: 0
      add :pageview_count, :integer, default: 0
      add :entry_url, :string
      add :exit_url, :string
      add :referrer, :string
      add :utm_source, :string
      add :utm_medium, :string
      add :utm_campaign, :string
      add :utm_term, :string
      add :utm_content, :string
      add :country, :string
      add :city, :string
      add :device_type, :string
      add :browser, :string
      add :os, :string
      add :is_bounce, :boolean, default: true

      timestamps()
    end

    create index(:sessions, [:site_id, :visitor_id])
    create index(:sessions, [:site_id, :started_at])
  end
end
