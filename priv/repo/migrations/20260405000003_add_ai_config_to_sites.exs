defmodule Spectabas.Repo.Migrations.AddAiConfigToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :ai_config_encrypted, :binary
    end
  end
end
