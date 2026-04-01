defmodule Spectabas.Repo.Migrations.AddAdPlatformCredentialsToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :ad_credentials_encrypted, :binary
    end
  end
end
