defmodule Spectabas.Goals.GoalStat do
  use Ecto.Schema
  import Ecto.Changeset

  schema "goal_stats" do
    field :completions, :integer, default: 0
    field :unique_completers, :integer, default: 0
    field :conversion_rate, :float, default: 0.0
    field :total_visitors, :integer, default: 0
    field :top_sources, {:array, :map}, default: []
    field :window_days, :integer, default: 7
    field :refreshed_at, :utc_datetime

    belongs_to :site, Spectabas.Sites.Site
    belongs_to :goal, Spectabas.Goals.Goal
  end

  @required ~w(site_id goal_id refreshed_at)a
  @optional ~w(completions unique_completers conversion_rate total_visitors top_sources window_days)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:goal_id)
  end
end
