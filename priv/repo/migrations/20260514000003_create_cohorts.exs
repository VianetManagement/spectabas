defmodule Spectabas.Repo.Migrations.CreateCohorts do
  use Ecto.Migration

  def change do
    create table(:cohorts) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      # Creator. Null if the user was later deleted; the cohort survives.
      add :user_id, references(:users, on_delete: :nilify_all)

      add :name, :string, size: 100, null: false
      add :description, :text

      # Array of filter maps, same shape as Spectabas.Analytics.Segment:
      # [%{"field" => "utm_campaign", "op" => "equals", "value" => "summer"}, ...]
      # Stored as :map (single JSONB column) wrapping the list, so Ecto's
      # cast plays nicely — `%{"filters" => [...]}` on the way in/out.
      add :filters, :map, null: false, default: %{}

      # "private" → only the creating user sees it
      # "site" → everyone with access to the site sees it
      add :visibility, :string, size: 20, null: false, default: "private"

      timestamps()
    end

    create index(:cohorts, [:site_id])
    create index(:cohorts, [:site_id, :user_id])
  end
end
