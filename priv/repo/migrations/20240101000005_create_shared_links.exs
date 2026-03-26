defmodule Spectabas.Repo.Migrations.CreateSharedLinks do
  use Ecto.Migration

  def change do
    create table(:shared_links) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :created_by, references(:users, on_delete: :nilify_all)
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:shared_links, [:token])
  end
end
