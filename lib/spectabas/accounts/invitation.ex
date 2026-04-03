defmodule Spectabas.Accounts.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "invitations" do
    field :email, :string
    field :token, :string, virtual: true
    field :token_hash, :string

    field :role, Ecto.Enum,
      values: [:platform_admin, :superadmin, :admin, :analyst, :viewer],
      default: :analyst

    field :account_id, :id
    belongs_to :account, Spectabas.Accounts.Account, define_field: false

    field :invited_by_id, :id
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new invitation.
  Generates a secure random token, hashes it, and sets expiry.
  """
  def create_changeset(invitation, attrs) do
    ttl_hours = Application.get_env(:spectabas, :invitation_ttl_hours, 48)
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    token_hash = hash_token(token)

    expires_at =
      DateTime.utc_now() |> DateTime.add(ttl_hours * 3600, :second) |> DateTime.truncate(:second)

    invitation
    |> cast(attrs, [:email, :role, :invited_by_id, :account_id])
    |> validate_required([:email, :role, :account_id])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> put_change(:token_hash, token_hash)
    |> put_change(:expires_at, expires_at)
    |> unique_constraint(:token_hash)
    |> then(fn cs ->
      if cs.valid?, do: put_change(cs, :token, token), else: cs
    end)
  end

  @doc """
  Hashes a plaintext token using SHA-256 and returns the hex-encoded hash.
  """
  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
