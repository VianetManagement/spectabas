defmodule Spectabas.Goals.Funnel do
  @moduledoc """
  Schema for conversion funnels. Steps are stored as a JSON array
  of maps, each with a type and matching criteria.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "funnels" do
    field :name, :string
    field :steps, {:array, :map}, default: []
    field :active, :boolean, default: true

    belongs_to :site, Spectabas.Sites.Site

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name site_id)a
  @optional_fields ~w(steps active)a

  def changeset(funnel, attrs) do
    funnel
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_steps()
    |> foreign_key_constraint(:site_id)
  end

  defp validate_steps(changeset) do
    case get_field(changeset, :steps) do
      steps when is_list(steps) and length(steps) >= 2 ->
        changeset

      steps when is_list(steps) ->
        add_error(changeset, :steps, "must have at least 2 steps")

      _ ->
        changeset
    end
  end
end
