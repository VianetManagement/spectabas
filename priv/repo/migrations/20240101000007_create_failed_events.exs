defmodule Spectabas.Repo.Migrations.CreateFailedEvents do
  use Ecto.Migration

  def change do
    create table(:failed_events) do
      add :payload, :text, null: false
      add :error, :text
      add :attempts, :integer, default: 0
      add :retry_after, :utc_datetime
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:failed_events, [:retry_after])
    create index(:failed_events, [:attempts])
  end
end
