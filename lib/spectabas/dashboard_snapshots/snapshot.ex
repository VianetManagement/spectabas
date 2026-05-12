defmodule Spectabas.DashboardSnapshots.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dashboard_snapshots" do
    field :kind, :string
    field :window_days, :integer
    field :data, :map
    field :refreshed_at, :utc_datetime

    belongs_to :site, Spectabas.Sites.Site
  end

  @required ~w(site_id kind window_days data refreshed_at)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> unique_constraint([:site_id, :kind])
  end
end
