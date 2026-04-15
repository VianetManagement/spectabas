defmodule Spectabas.Repo.Migrations.AddIdentityCookieNameToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :identity_cookie_name, :string
    end
  end
end
