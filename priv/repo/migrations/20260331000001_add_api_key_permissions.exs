defmodule Spectabas.Repo.Migrations.AddApiKeyPermissions do
  use Ecto.Migration

  def change do
    alter table(:api_keys) do
      add :scopes, {:array, :string},
        default: ["read:stats", "read:visitors", "write:events", "write:identify"]

      add :site_ids, {:array, :integer}, default: []
      add :expires_at, :utc_datetime, null: true
      add :last_ip, :string, null: true
    end
  end
end
