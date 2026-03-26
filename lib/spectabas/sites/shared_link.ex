defmodule Spectabas.Sites.SharedLink do
  use Ecto.Schema
  import Ecto.Changeset

  schema "shared_links" do
    belongs_to :site, Spectabas.Sites.Site
    field :token, :string
    field :created_by, :id
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps()
  end

  def changeset(shared_link, attrs) do
    shared_link
    |> cast(attrs, [:site_id, :token, :created_by, :expires_at, :revoked_at])
    |> validate_required([:site_id, :token])
    |> unique_constraint(:token)
  end

  def generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
