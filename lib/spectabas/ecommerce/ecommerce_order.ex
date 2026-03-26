defmodule Spectabas.Ecommerce.EcommerceOrder do
  @moduledoc """
  Schema for ecommerce orders tracked through the analytics platform.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "ecommerce_orders" do
    field :order_id, :string
    field :visitor_id, Ecto.UUID
    field :session_id, Ecto.UUID
    field :revenue, :decimal
    field :subtotal, :decimal
    field :tax, :decimal
    field :shipping, :decimal
    field :discount, :decimal
    field :currency, :string, default: "USD"
    field :items, {:array, :map}, default: []
    field :occurred_at, :utc_datetime

    belongs_to :site, Spectabas.Sites.Site

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(site_id order_id occurred_at)a
  @optional_fields ~w(visitor_id session_id revenue subtotal tax shipping discount currency items)a

  def changeset(order, attrs) do
    order
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:order_id, max: 255)
    |> validate_length(:currency, max: 10)
    |> foreign_key_constraint(:site_id)
    |> unique_constraint([:site_id, :order_id])
  end
end
