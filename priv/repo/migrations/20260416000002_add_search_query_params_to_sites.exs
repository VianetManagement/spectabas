defmodule Spectabas.Repo.Migrations.AddSearchQueryParamsToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :search_query_params, {:array, :string}, default: []
    end
  end
end
