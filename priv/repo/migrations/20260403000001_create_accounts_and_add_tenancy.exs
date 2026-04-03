defmodule Spectabas.Repo.Migrations.CreateAccountsAndAddTenancy do
  use Ecto.Migration

  def up do
    # 1. Create accounts table
    create table(:accounts) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :site_limit, :integer, null: false, default: 10
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:accounts, [:slug])

    # 2. Add account_id to users (nullable — platform_admin has NULL)
    alter table(:users) do
      add :account_id, references(:accounts, on_delete: :restrict), null: true
    end

    # 3. Add account_id to sites (nullable initially, made NOT NULL after backfill)
    alter table(:sites) do
      add :account_id, references(:accounts, on_delete: :restrict), null: true
    end

    # 4. Add account_id to invitations (nullable initially, made NOT NULL after backfill)
    alter table(:invitations) do
      add :account_id, references(:accounts, on_delete: :restrict), null: true
    end

    # 5. Backfill: create "Vianet" account for all existing data
    execute """
    INSERT INTO accounts (name, slug, site_limit, active, inserted_at, updated_at)
    VALUES ('Vianet', 'vianet', 100, true, NOW(), NOW())
    """

    # 6. Assign all existing users and sites to Vianet account
    execute "UPDATE users SET account_id = (SELECT id FROM accounts WHERE slug = 'vianet')"
    execute "UPDATE sites SET account_id = (SELECT id FROM accounts WHERE slug = 'vianet')"

    execute "UPDATE invitations SET account_id = (SELECT id FROM accounts WHERE slug = 'vianet') WHERE account_id IS NULL"

    # 7. Promote jeff@vianet.us to platform_admin (account_id = NULL)
    execute "UPDATE users SET role = 'platform_admin', account_id = NULL WHERE email = 'jeff@vianet.us'"

    # 8. Make account_id NOT NULL on sites and invitations (users stays nullable for platform_admin)
    execute "ALTER TABLE sites ALTER COLUMN account_id SET NOT NULL"
    execute "ALTER TABLE invitations ALTER COLUMN account_id SET NOT NULL"

    # 9. Add indexes
    create index(:users, [:account_id])
    create index(:sites, [:account_id])
    create index(:invitations, [:account_id])
  end

  def down do
    # Remove indexes first
    drop_if_exists index(:invitations, [:account_id])
    drop_if_exists index(:sites, [:account_id])
    drop_if_exists index(:users, [:account_id])

    # Revert jeff to superadmin
    execute "UPDATE users SET role = 'superadmin' WHERE role = 'platform_admin'"

    # Remove account_id columns
    alter table(:invitations) do
      remove :account_id
    end

    alter table(:sites) do
      remove :account_id
    end

    alter table(:users) do
      remove :account_id
    end

    # Drop accounts table
    drop table(:accounts)
  end
end
