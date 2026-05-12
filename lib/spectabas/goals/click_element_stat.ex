defmodule Spectabas.Goals.ClickElementStat do
  use Ecto.Schema
  import Ecto.Changeset

  schema "click_element_stats" do
    field :element_key, :string
    field :element_text, :string
    field :element_id, :string
    field :element_tag, :string
    field :element_href, :string
    field :element_classes, :string
    field :clicks, :integer, default: 0
    field :visitors, :integer, default: 0
    field :first_seen, :utc_datetime
    field :last_seen, :utc_datetime
    field :sample_pages, {:array, :string}, default: []
    field :refreshed_at, :utc_datetime

    belongs_to :site, Spectabas.Sites.Site
  end

  @required ~w(site_id element_key element_tag clicks visitors refreshed_at)a
  @optional ~w(element_text element_id element_href element_classes first_seen last_seen sample_pages)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:element_key, max: 512)
    |> unique_constraint([:site_id, :element_key])
  end
end
