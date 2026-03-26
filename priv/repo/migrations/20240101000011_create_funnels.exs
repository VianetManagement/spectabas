defmodule Spectabas.Repo.Migrations.CreateFunnels do
  use Ecto.Migration

  def change do
    create table(:funnels) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :steps, :map, null: false, default: "[]"
      add :active, :boolean, default: true

      timestamps()
    end
  end
end
