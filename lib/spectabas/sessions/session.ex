defmodule Spectabas.Sessions.Session do
  @moduledoc """
  Ecto schema for the `sessions` table.
  Uses binary_id as primary key with autogeneration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sessions" do
    field :site_id, :id
    field :visitor_id, Ecto.UUID
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :duration_s, :integer, default: 0
    field :pageview_count, :integer, default: 0
    field :entry_url, :string
    field :exit_url, :string
    field :referrer, :string
    field :utm_source, :string
    field :utm_medium, :string
    field :utm_campaign, :string
    field :utm_term, :string
    field :utm_content, :string
    field :country, :string
    field :city, :string
    field :device_type, :string
    field :browser, :string
    field :os, :string
    field :is_bounce, :boolean, default: true

    timestamps()
  end

  @required_fields ~w(site_id visitor_id started_at)a
  @optional_fields ~w(ended_at duration_s pageview_count entry_url exit_url
                       referrer utm_source utm_medium utm_campaign utm_term
                       utm_content country city device_type browser os is_bounce)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
