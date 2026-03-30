defmodule Spectabas.Repo.Migrations.AddVisitorUniqueIndexes do
  use Ecto.Migration

  def up do
    # Clean up duplicate fingerprints — keep the oldest visitor per (site_id, fingerprint_id)
    execute """
    DELETE FROM visitors
    WHERE id IN (
      SELECT id FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY site_id, fingerprint_id
          ORDER BY inserted_at ASC
        ) AS rn
        FROM visitors
        WHERE fingerprint_id IS NOT NULL AND fingerprint_id != ''
      ) dupes
      WHERE rn > 1
    )
    """

    # Clean up duplicate cookie_ids — keep the oldest
    execute """
    DELETE FROM visitors
    WHERE id IN (
      SELECT id FROM (
        SELECT id, ROW_NUMBER() OVER (
          PARTITION BY site_id, cookie_id
          ORDER BY inserted_at ASC
        ) AS rn
        FROM visitors
        WHERE cookie_id IS NOT NULL AND cookie_id != ''
      ) dupes
      WHERE rn > 1
    )
    """

    # Now safe to add unique indexes
    create_if_not_exists unique_index(:visitors, [:site_id, :cookie_id],
                           where: "cookie_id IS NOT NULL AND cookie_id != ''",
                           name: :visitors_site_id_cookie_id_unique
                         )

    create_if_not_exists unique_index(:visitors, [:site_id, :fingerprint_id],
                           where: "fingerprint_id IS NOT NULL AND fingerprint_id != ''",
                           name: :visitors_site_id_fingerprint_id_unique
                         )
  end

  def down do
    drop_if_exists index(:visitors, [:site_id, :cookie_id],
                     name: :visitors_site_id_cookie_id_unique
                   )

    drop_if_exists index(:visitors, [:site_id, :fingerprint_id],
                     name: :visitors_site_id_fingerprint_id_unique
                   )
  end
end
