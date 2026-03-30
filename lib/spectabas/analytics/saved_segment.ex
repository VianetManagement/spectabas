defmodule Spectabas.Analytics.SavedSegment do
  use Ecto.Schema
  import Ecto.Changeset

  schema "saved_segments" do
    belongs_to :user, Spectabas.Accounts.User
    belongs_to :site, Spectabas.Sites.Site
    field :name, :string
    field :filters, {:array, :map}, default: []

    timestamps(type: :utc_datetime)
  end

  def changeset(segment, attrs) do
    segment
    |> cast(attrs, [:name, :filters, :user_id, :site_id])
    |> validate_required([:name, :filters, :user_id, :site_id])
    |> validate_length(:name, min: 1, max: 100)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:site_id)
  end
end
