defmodule Spectabas.Repo.Migrations.CreateGeoipDownloads do
  use Ecto.Migration

  def change do
    create table(:geoip_downloads) do
      add :database_name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :file_size, :integer
      add :error_message, :text
      add :duration_ms, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:geoip_downloads, [:database_name, :inserted_at])
  end
end
