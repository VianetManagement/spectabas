defmodule Spectabas.Repo.Migrations.CreateClickElementNames do
  use Ecto.Migration

  def change do
    create table(:click_element_names) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :element_key, :string, null: false
      add :friendly_name, :string, null: false
      add :notes, :text
      add :ignored, :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:click_element_names, [:site_id, :element_key])
  end
end
