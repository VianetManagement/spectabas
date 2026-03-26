defmodule Spectabas.Repo.Migrations.CreateGoals do
  use Ecto.Migration

  def change do
    create table(:goals) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :goal_type, :string, null: false, default: "pageview"
      add :page_path, :string
      add :event_name, :string
      add :active, :boolean, default: true

      timestamps()
    end
  end
end
