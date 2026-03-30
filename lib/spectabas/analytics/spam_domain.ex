defmodule Spectabas.Analytics.SpamDomain do
  @moduledoc "Ecto schema for custom spam domains stored in the database."

  use Ecto.Schema
  import Ecto.Changeset

  schema "spam_domains" do
    field :domain, :string
    field :source, :string, default: "manual"
    field :hits_total, :integer, default: 0
    field :last_seen_at, :utc_datetime
    field :active, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  def changeset(spam_domain, attrs) do
    spam_domain
    |> cast(attrs, [:domain, :source, :hits_total, :last_seen_at, :active])
    |> validate_required([:domain])
    |> validate_inclusion(:source, ["manual", "auto", "builtin"])
    |> update_change(:domain, &String.downcase/1)
    |> unique_constraint(:domain)
  end
end
