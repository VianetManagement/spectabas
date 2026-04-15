defmodule Spectabas.Repo.Migrations.AddExternalIdToVisitors do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    alter table(:visitors) do
      add :external_id, :string
    end

    create_if_not_exists index(:visitors, [:site_id, :external_id],
                           name: "visitors_site_id_external_id_idx",
                           where: "external_id IS NOT NULL AND external_id <> ''",
                           concurrently: true
                         )
  end
end
