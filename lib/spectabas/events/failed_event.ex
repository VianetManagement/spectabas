defmodule Spectabas.Events.FailedEvent do
  @moduledoc """
  Ecto schema for the `failed_events` table.
  Stores event payloads that could not be inserted into ClickHouse
  for later retry. No `updated_at` timestamp.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "failed_events" do
    field :payload, :string
    field :error, :string
    field :attempts, :integer, default: 0
    field :retry_after, :utc_datetime
    field :inserted_at, :utc_datetime
  end

  @required_fields ~w(payload inserted_at)a
  @optional_fields ~w(error attempts retry_after)a

  def changeset(failed_event, attrs) do
    failed_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
