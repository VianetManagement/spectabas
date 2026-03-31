defmodule Spectabas.Repo.Migrations.CreateApiAccessLogs do
  use Ecto.Migration

  def change do
    create table(:api_access_logs) do
      add :api_key_id, references(:api_keys, on_delete: :nilify_all)
      add :key_prefix, :string
      add :user_id, references(:users, on_delete: :nilify_all)
      add :method, :string
      add :path, :string
      add :site_id, :integer
      add :status_code, :integer
      add :ip_address, :string
      add :user_agent, :string, size: 256
      add :duration_ms, :integer
      timestamps(updated_at: false)
    end

    create index(:api_access_logs, [:api_key_id])
    create index(:api_access_logs, [:inserted_at])
  end
end
