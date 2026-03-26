defmodule Spectabas.Repo.Migrations.CreateVisitors do
  use Ecto.Migration

  def change do
    create table(:visitors, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :fingerprint_id, :string
      add :cookie_id, :string
      add :user_id, :string
      add :email, :string
      add :email_hash, :string
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :last_ip, :string
      add :known_ips, {:array, :string}, default: []
      add :gdpr_mode, :string, default: "on"

      timestamps()
    end

    create index(:visitors, [:site_id, :fingerprint_id])
    create index(:visitors, [:site_id, :cookie_id])
    create index(:visitors, [:site_id, :user_id])
    create index(:visitors, [:site_id, :email_hash])
  end
end
