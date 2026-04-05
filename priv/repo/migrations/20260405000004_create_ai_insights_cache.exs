defmodule Spectabas.Repo.Migrations.CreateAiInsightsCache do
  use Ecto.Migration

  def change do
    create table(:ai_insights_cache) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :provider, :string, null: false
      add :model, :string
      add :generated_at, :utc_datetime, null: false
    end

    create unique_index(:ai_insights_cache, [:site_id])
  end
end
