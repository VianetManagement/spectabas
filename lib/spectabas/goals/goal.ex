defmodule Spectabas.Goals.Goal do
  @moduledoc """
  Schema for analytics goals. Supports pageview path matching
  and custom event name matching.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "goals" do
    field :name, :string
    field :goal_type, :string, default: "pageview"
    field :page_path, :string
    field :event_name, :string
    field :element_selector, :string
    field :active, :boolean, default: true

    belongs_to :site, Spectabas.Sites.Site

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name goal_type site_id)a
  @optional_fields ~w(page_path event_name element_selector active)a

  def changeset(goal, attrs) do
    goal
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:goal_type, ~w(pageview custom_event click_element))
    |> validate_goal_fields()
    |> foreign_key_constraint(:site_id)
  end

  defp validate_goal_fields(changeset) do
    case get_field(changeset, :goal_type) do
      "pageview" ->
        validate_required(changeset, [:page_path])

      "custom_event" ->
        validate_required(changeset, [:event_name])

      "click_element" ->
        changeset
        |> validate_required([:element_selector])
        |> validate_length(:element_selector, max: 500)

      _ ->
        changeset
    end
  end
end
