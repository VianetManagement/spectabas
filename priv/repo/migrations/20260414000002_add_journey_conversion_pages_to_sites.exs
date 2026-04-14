defmodule Spectabas.Repo.Migrations.AddJourneyConversionPagesToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :journey_conversion_pages, {:array, :string}, default: []
    end
  end
end
