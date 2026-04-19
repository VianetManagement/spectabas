defmodule Spectabas.Repo.Migrations.AddNotesToVisitors do
  use Ecto.Migration

  def change do
    alter table(:visitors) do
      add :notes, :text
    end
  end
end
