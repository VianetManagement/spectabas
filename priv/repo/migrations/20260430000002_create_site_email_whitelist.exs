defmodule Spectabas.Repo.Migrations.CreateSiteEmailWhitelist do
  use Ecto.Migration

  def change do
    create table(:site_email_whitelist) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :email_hash, :string, size: 64, null: false
      add :source, :string, size: 40, null: false, default: "manual"
      add :added_by_user_id, references(:users, on_delete: :nilify_all), null: true
      add :notes, :text, null: true

      timestamps()
    end

    create unique_index(:site_email_whitelist, [:site_id, :email_hash])
    create index(:site_email_whitelist, [:site_id])
  end
end
