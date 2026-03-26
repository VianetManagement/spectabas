defmodule Spectabas.Accounts.APIKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_keys" do
    belongs_to :user, Spectabas.Accounts.User

    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:user_id, :name, :key_hash, :key_prefix, :last_used_at, :revoked_at])
    |> validate_required([:user_id, :name, :key_hash, :key_prefix])
    |> validate_length(:name, max: 255)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:key_hash)
  end
end
