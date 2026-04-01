defmodule Spectabas.Repo.Migrations.AddApiLogBodiesAndCleanup do
  use Ecto.Migration

  def change do
    alter table(:api_access_logs) do
      add :request_body, :text
      add :response_body, :text
    end
  end
end
