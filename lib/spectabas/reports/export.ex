defmodule Spectabas.Reports.Export do
  @moduledoc """
  Schema for data exports. Tracks export status from pending
  through completion or failure.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "exports" do
    field :format, :string, default: "csv"
    field :date_from, :utc_datetime
    field :date_to, :utc_datetime
    field :status, :string, default: "pending"
    field :file_path, :string
    field :error, :string
    field :completed_at, :utc_datetime

    belongs_to :site, Spectabas.Sites.Site
    belongs_to :user, Spectabas.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(site_id user_id)a
  @optional_fields ~w(format date_from date_to status file_path error completed_at)a

  def changeset(export, attrs) do
    export
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:format, ~w(csv json))
    |> validate_inclusion(:status, ~w(pending processing completed failed))
    |> foreign_key_constraint(:site_id)
    |> foreign_key_constraint(:user_id)
  end
end
