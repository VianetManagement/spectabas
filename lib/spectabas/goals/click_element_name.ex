defmodule Spectabas.Goals.ClickElementName do
  use Ecto.Schema
  import Ecto.Changeset

  schema "click_element_names" do
    field :element_key, :string
    field :friendly_name, :string
    field :notes, :string
    field :ignored, :boolean, default: false

    belongs_to :site, Spectabas.Sites.Site

    timestamps(type: :utc_datetime)
  end

  @required ~w(element_key friendly_name site_id)a
  @optional ~w(notes ignored)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:element_key, max: 500)
    |> validate_length(:friendly_name, max: 200)
    |> unique_constraint([:site_id, :element_key])
  end
end
