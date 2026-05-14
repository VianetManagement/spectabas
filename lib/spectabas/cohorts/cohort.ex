defmodule Spectabas.Cohorts.Cohort do
  use Ecto.Schema
  import Ecto.Changeset

  alias Spectabas.Analytics.Segment

  schema "cohorts" do
    field :site_id, :id
    field :user_id, :id
    field :name, :string
    field :description, :string
    # filters is stored as %{"filters" => [...]} JSONB. Wrapping in a
    # key like this is the cleanest way to put a list inside an Ecto
    # :map field — the schema flattens it for the view layer below.
    field :filters, :map, default: %{"filters" => []}
    field :visibility, :string, default: "private"

    timestamps()
  end

  @required ~w(site_id name)a
  @optional ~w(user_id description filters visibility)a
  @valid_visibility ~w(private site)

  def changeset(cohort, attrs) do
    cohort
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_inclusion(:visibility, @valid_visibility)
    |> validate_filters()
  end

  defp validate_filters(changeset) do
    case get_change(changeset, :filters) do
      nil ->
        changeset

      %{"filters" => list} when is_list(list) ->
        if Enum.all?(list, &valid_filter_shape?/1),
          do: changeset,
          else: add_error(changeset, :filters, "contains an invalid filter")

      _ ->
        add_error(changeset, :filters, "must be a map with a 'filters' list")
    end
  end

  defp valid_filter_shape?(%{"field" => f, "op" => op, "value" => v})
       when is_binary(f) and is_binary(op) and (is_binary(v) or is_list(v)) do
    f in Segment.allowed_field_names() and op in ~w(is is_not contains not_contains)
  end

  defp valid_filter_shape?(_), do: false

  @doc "Pulls the list of filters out of the wrapped storage shape."
  def filters_list(%__MODULE__{filters: %{"filters" => list}}) when is_list(list), do: list
  def filters_list(_), do: []
end
