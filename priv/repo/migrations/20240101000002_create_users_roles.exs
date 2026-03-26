defmodule Spectabas.Repo.Migrations.CreateUsersRoles do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :role, :string, default: "analyst", null: false
      add :display_name, :string
      add :totp_secret, :string
      add :totp_enabled, :boolean, default: false
      add :totp_enabled_at, :utc_datetime
      add :last_sign_in_at, :utc_datetime
      add :last_sign_in_ip, :string
    end

    create table(:user_site_permissions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "viewer"

      timestamps()
    end

    create unique_index(:user_site_permissions, [:user_id, :site_id])
  end
end
