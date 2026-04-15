defmodule Spectabas.Visitors.Visitor do
  @moduledoc """
  Ecto schema for the `visitors` table.
  Uses binary_id as primary key with autogeneration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "visitors" do
    field :site_id, :id
    field :fingerprint_id, :string
    field :cookie_id, :string
    field :user_id, :string
    field :email, :string
    field :email_hash, :string
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :last_ip, :string
    field :known_ips, {:array, :string}, default: []
    field :gdpr_mode, :string, default: "on"
    field :external_id, :string

    timestamps()
  end

  @required_fields ~w(site_id)a
  @optional_fields ~w(fingerprint_id cookie_id user_id email email_hash
                       first_seen_at last_seen_at last_ip known_ips gdpr_mode external_id)a

  def changeset(visitor, attrs) do
    visitor
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:gdpr_mode, ~w(on off))
    |> unique_constraint([:site_id, :cookie_id], name: :visitors_site_id_cookie_id_unique)
    |> unique_constraint([:site_id, :fingerprint_id],
      name: :visitors_site_id_fingerprint_id_unique
    )
  end
end
