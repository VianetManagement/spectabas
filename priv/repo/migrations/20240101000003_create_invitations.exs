defmodule Spectabas.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations) do
      add :email, :string, null: false
      add :token_hash, :string, null: false
      add :role, :string, null: false, default: "analyst"
      add :invited_by_id, references(:users, on_delete: :nilify_all)
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime

      timestamps()
    end

    create unique_index(:invitations, [:token_hash])
  end
end
