defmodule Spectabas.Repo.Migrations.AddWebauthnAndForce2fa do
  use Ecto.Migration

  def change do
    create table(:webauthn_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :integer, default: 0
      add :name, :string, default: "Security Key"
      timestamps()
    end

    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])

    alter table(:users) do
      add :force_2fa, :boolean, default: false
    end
  end
end
