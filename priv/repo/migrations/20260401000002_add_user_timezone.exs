defmodule Spectabas.Repo.Migrations.AddUserTimezone do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :timezone, :string, default: "America/New_York"
    end
  end
end
