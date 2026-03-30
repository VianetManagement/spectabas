defmodule Spectabas.Repo.Migrations.CreateSavedSegments do
  use Ecto.Migration

  def change do
    create table(:saved_segments) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :filters, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:saved_segments, [:user_id, :site_id])
  end
end
