defmodule Spectabas.Repo.Migrations.AddElementSelectorToGoals do
  use Ecto.Migration

  def change do
    alter table(:goals) do
      add :element_selector, :string
    end
  end
end
