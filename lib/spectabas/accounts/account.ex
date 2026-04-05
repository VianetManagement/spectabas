defmodule Spectabas.Accounts.Account do
  use Ecto.Schema
  import Ecto.Changeset

  schema "accounts" do
    field :name, :string
    field :slug, :string
    field :site_limit, :integer, default: 10
    field :active, :boolean, default: true
    field :require_mfa, :boolean, default: false

    has_many :users, Spectabas.Accounts.User
    has_many :sites, Spectabas.Sites.Site
    has_many :invitations, Spectabas.Accounts.Invitation

    timestamps(type: :utc_datetime)
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :slug, :site_limit, :active, :require_mfa])
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 255)
    |> validate_format(:slug, ~r/^[a-z0-9\-]+$/,
      message: "must be lowercase letters, numbers, and hyphens"
    )
    |> validate_length(:slug, min: 2, max: 100)
    |> validate_number(:site_limit, greater_than: 0, less_than_or_equal_to: 1000)
    |> unique_constraint(:slug)
  end
end
