defmodule Spectabas.Accounts.WebauthnCredential do
  use Ecto.Schema
  import Ecto.Changeset

  schema "webauthn_credentials" do
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :name, :string, default: "Security Key"
    belongs_to :user, Spectabas.Accounts.User
    timestamps()
  end

  def changeset(cred, attrs) do
    cred
    |> cast(attrs, [:user_id, :credential_id, :public_key, :sign_count, :name])
    |> validate_required([:user_id, :credential_id, :public_key])
    |> unique_constraint(:credential_id)
  end
end
