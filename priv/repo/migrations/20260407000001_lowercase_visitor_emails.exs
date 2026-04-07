defmodule Spectabas.Repo.Migrations.LowercaseVisitorEmails do
  use Ecto.Migration

  def up do
    execute "UPDATE visitors SET email = LOWER(TRIM(email)) WHERE email IS NOT NULL AND email != '' AND email != LOWER(TRIM(email))"
  end

  def down do
    # Irreversible — original casing is lost
    :ok
  end
end
