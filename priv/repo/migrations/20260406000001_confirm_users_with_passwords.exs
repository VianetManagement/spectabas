defmodule Spectabas.Repo.Migrations.ConfirmUsersWithPasswords do
  use Ecto.Migration

  def up do
    # Fix users who accepted invitations (have password) but were never confirmed.
    # Without confirmed_at, the magic link login flow rejects them.
    execute """
    UPDATE users SET confirmed_at = inserted_at
    WHERE confirmed_at IS NULL AND hashed_password IS NOT NULL
    """
  end

  def down do
    :ok
  end
end
