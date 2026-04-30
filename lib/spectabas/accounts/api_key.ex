defmodule Spectabas.Accounts.APIKey do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(read:stats read:visitors write:events write:identify write:whitelist admin:sites)

  schema "api_keys" do
    belongs_to :user, Spectabas.Accounts.User

    field :name, :string
    field :key_hash, :string
    field :key_prefix, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    field :scopes, {:array, :string},
      default: ["read:stats", "read:visitors", "write:events", "write:identify"]

    field :site_ids, {:array, :integer}, default: []
    field :expires_at, :utc_datetime
    field :last_ip, :string

    timestamps(type: :utc_datetime)
  end

  def valid_scopes, do: @valid_scopes

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :user_id,
      :name,
      :key_hash,
      :key_prefix,
      :last_used_at,
      :revoked_at,
      :scopes,
      :site_ids,
      :expires_at,
      :last_ip
    ])
    |> validate_required([:user_id, :name, :key_hash, :key_prefix])
    |> validate_length(:name, max: 255)
    |> validate_scopes()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:key_hash)
  end

  defp validate_scopes(changeset) do
    case get_change(changeset, :scopes) do
      nil ->
        changeset

      scopes ->
        invalid = Enum.reject(scopes, &(&1 in @valid_scopes))

        if invalid == [] do
          changeset
        else
          add_error(changeset, :scopes, "contains invalid scopes: #{Enum.join(invalid, ", ")}")
        end
    end
  end
end
