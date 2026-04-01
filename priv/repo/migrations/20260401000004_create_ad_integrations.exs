defmodule Spectabas.Repo.Migrations.CreateAdIntegrations do
  use Ecto.Migration

  def change do
    create table(:ad_integrations) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :platform, :string, null: false
      add :account_id, :string, default: ""
      add :account_name, :string
      add :access_token_encrypted, :binary, null: false
      add :refresh_token_encrypted, :binary, null: false
      add :token_expires_at, :utc_datetime
      add :scopes, {:array, :string}, default: []
      add :extra, :map, default: %{}
      add :status, :string, default: "active"
      add :last_synced_at, :utc_datetime
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ad_integrations, [:site_id, :platform, :account_id])
    create index(:ad_integrations, [:site_id])
  end
end
