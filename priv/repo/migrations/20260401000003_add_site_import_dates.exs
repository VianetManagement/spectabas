defmodule Spectabas.Repo.Migrations.AddSiteImportDates do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :native_start_date, :date
      add :import_end_date, :date
    end
  end
end
