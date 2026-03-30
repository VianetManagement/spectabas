defmodule Spectabas.Repo.Migrations.AddVisitorUniqueIndexes do
  use Ecto.Migration

  def change do
    # Prevent duplicate visitors from race conditions in resolve_visitor.
    # These replace the existing non-unique indexes.
    # Using create_if_not_exists for idempotent deploys.
    create_if_not_exists unique_index(:visitors, [:site_id, :cookie_id],
                           where: "cookie_id IS NOT NULL AND cookie_id != ''",
                           name: :visitors_site_id_cookie_id_unique
                         )

    create_if_not_exists unique_index(:visitors, [:site_id, :fingerprint_id],
                           where: "fingerprint_id IS NOT NULL AND fingerprint_id != ''",
                           name: :visitors_site_id_fingerprint_id_unique
                         )
  end
end
