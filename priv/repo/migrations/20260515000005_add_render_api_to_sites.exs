defmodule Spectabas.Repo.Migrations.AddRenderApiToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :render_api_key_encrypted, :binary
      add :render_owner_id, :string
      add :render_service_ids, {:array, :string}, default: []
      add :render_log_cursors, :map, default: %{}
    end
  end
end
