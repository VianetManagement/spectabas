defmodule Spectabas.Repo.Migrations.CreateInsightDismissals do
  use Ecto.Migration

  def change do
    # Per-user dismissals (decision in chat 2026-05-14). One insight may
    # be dismissed by some users on the team but still visible to others.
    create table(:insight_dismissals) do
      add :insight_id, references(:insights, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:insight_dismissals, [:insight_id, :user_id])
    create index(:insight_dismissals, [:user_id])
  end
end
