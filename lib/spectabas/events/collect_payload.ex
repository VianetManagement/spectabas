defmodule Spectabas.Events.CollectPayload do
  @moduledoc """
  Ecto embedded schema for validating incoming event payloads.
  All external input is cast, validated for type/length/range, and the
  custom properties map is checked for key/value limits.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(pageview custom duration ecommerce_order ecommerce_item xdtoken)

  @primary_key false
  embedded_schema do
    field :t, :string, default: "pageview"
    field :n, :string, default: ""
    field :u, :string, default: ""
    field :r, :string, default: ""
    field :vid, :string
    field :sid, :string
    field :d, :integer, default: 0
    field :sw, :integer, default: 0
    field :sh, :integer, default: 0
    field :p, :map, default: %{}
  end

  @doc """
  Validate a raw params map and return `{:ok, %CollectPayload{}}` or `{:error, changeset}`.
  """
  def validate(params) when is_map(params) do
    %__MODULE__{}
    |> cast(params, [:t, :n, :u, :r, :vid, :sid, :d, :sw, :sh, :p])
    |> validate_inclusion(:t, @valid_types)
    |> validate_length(:n, max: 256)
    |> validate_length(:u, max: 2048)
    |> validate_length(:r, max: 2048)
    |> validate_length(:vid, max: 256)
    |> validate_length(:sid, max: 256)
    |> validate_number(:d, greater_than_or_equal_to: 0, less_than_or_equal_to: 86_400_000)
    |> validate_number(:sw, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:sh, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
    |> validate_props()
    |> apply_action(:validate)
  end

  def validate(_), do: {:error, :invalid_payload}

  defp validate_props(changeset) do
    props = get_field(changeset, :p) || %{}

    cond do
      not is_map(props) ->
        add_error(changeset, :p, "must be a map")

      map_size(props) > 20 ->
        add_error(changeset, :p, "must have at most 20 keys")

      not all_keys_valid?(props) ->
        add_error(changeset, :p, "all keys must be strings of at most 64 characters")

      not all_values_valid?(props) ->
        add_error(changeset, :p, "all values must be strings of at most 256 characters")

      true ->
        changeset
    end
  end

  defp all_keys_valid?(props) do
    Enum.all?(props, fn {k, _v} ->
      is_binary(k) and byte_size(k) <= 64
    end)
  end

  defp all_values_valid?(props) do
    Enum.all?(props, fn {_k, v} ->
      is_binary(v) and byte_size(v) <= 256
    end)
  end
end
