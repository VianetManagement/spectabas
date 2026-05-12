defmodule Spectabas.Repo.Migrations.CreateClickElementStats do
  use Ecto.Migration

  def change do
    create table(:click_element_stats) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :element_key, :string, null: false, size: 512
      add :element_text, :text
      add :element_id, :string, size: 512
      add :element_tag, :string, size: 32
      add :element_href, :text
      add :element_classes, :text
      add :clicks, :bigint, null: false, default: 0
      add :visitors, :bigint, null: false, default: 0
      add :first_seen, :utc_datetime
      add :last_seen, :utc_datetime
      add :sample_pages, {:array, :string}, default: []
      add :refreshed_at, :utc_datetime, null: false
    end

    create unique_index(:click_element_stats, [:site_id, :element_key])
    create index(:click_element_stats, [:site_id, :clicks])
    create index(:click_element_stats, [:site_id, :element_tag])
  end
end
