defmodule Spectabas.Repo.Migrations.CreateGoalAndFunnelStats do
  use Ecto.Migration

  def change do
    create table(:goal_stats) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :goal_id, references(:goals, on_delete: :delete_all), null: false
      add :completions, :bigint, null: false, default: 0
      add :unique_completers, :bigint, null: false, default: 0
      add :conversion_rate, :float, null: false, default: 0.0
      add :total_visitors, :bigint, null: false, default: 0
      add :top_sources, :map, default: "[]"
      add :window_days, :integer, null: false, default: 7
      add :refreshed_at, :utc_datetime, null: false
    end

    create unique_index(:goal_stats, [:goal_id])
    create index(:goal_stats, [:site_id])

    create table(:funnel_stats) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :funnel_id, references(:funnels, on_delete: :delete_all), null: false
      add :entered, :bigint, null: false, default: 0
      add :completed, :bigint, null: false, default: 0
      add :conversion_rate, :float, null: false, default: 0.0
      add :window_days, :integer, null: false, default: 30
      add :refreshed_at, :utc_datetime, null: false
    end

    create unique_index(:funnel_stats, [:funnel_id])
    create index(:funnel_stats, [:site_id])
  end
end
