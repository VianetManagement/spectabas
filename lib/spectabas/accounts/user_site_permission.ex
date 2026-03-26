defmodule Spectabas.Accounts.UserSitePermission do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_site_permissions" do
    belongs_to :user, Spectabas.Accounts.User
    belongs_to :site, Spectabas.Sites.Site

    field :role, Ecto.Enum, values: [:admin, :analyst, :viewer], default: :viewer

    timestamps(type: :utc_datetime)
  end

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:user_id, :site_id, :role])
    |> validate_required([:user_id, :site_id, :role])
    |> validate_inclusion(:role, [:admin, :analyst, :viewer])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:site_id)
    |> unique_constraint([:user_id, :site_id])
  end
end
