defmodule Spectabas.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs) do
      add :event, :string, null: false
      add :metadata, :map, default: %{}
      add :user_id, references(:users, on_delete: :nilify_all)
      add :occurred_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime, default: fragment("now()")
    end

    create index(:audit_logs, [:event])
    create index(:audit_logs, [:occurred_at])
    create index(:audit_logs, [:user_id])
  end
end
