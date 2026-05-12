defmodule Spectabas.Goals.FunnelStat do
  use Ecto.Schema
  import Ecto.Changeset

  schema "funnel_stats" do
    field :entered, :integer, default: 0
    field :completed, :integer, default: 0
    field :conversion_rate, :float, default: 0.0
    field :window_days, :integer, default: 30
    field :refreshed_at, :utc_datetime

    belongs_to :site, Spectabas.Sites.Site
    belongs_to :funnel, Spectabas.Goals.Funnel
  end

  @required ~w(site_id funnel_id refreshed_at)a
  @optional ~w(entered completed conversion_rate window_days)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:funnel_id)
  end
end
