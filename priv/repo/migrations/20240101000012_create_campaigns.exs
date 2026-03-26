defmodule Spectabas.Repo.Migrations.CreateCampaigns do
  use Ecto.Migration

  def change do
    create table(:campaigns) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :utm_source, :string
      add :utm_medium, :string
      add :utm_campaign, :string
      add :utm_term, :string
      add :utm_content, :string
      add :destination_url, :string
      add :active, :boolean, default: true

      timestamps()
    end
  end
end
