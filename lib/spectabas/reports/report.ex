defmodule Spectabas.Reports.Report do
  @moduledoc """
  Schema for scheduled and ad-hoc analytics reports.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "reports" do
    field :name, :string
    field :description, :string
    field :definition, :map, default: %{}
    field :schedule, :string
    field :recipients, {:array, :string}, default: []
    field :last_sent_at, :utc_datetime
    field :active, :boolean, default: true

    belongs_to :site, Spectabas.Sites.Site
    belongs_to :creator, Spectabas.Accounts.User, foreign_key: :created_by

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name site_id)a
  @optional_fields ~w(description definition schedule recipients last_sent_at active created_by)a

  def changeset(report, attrs) do
    report
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
    |> validate_inclusion(:schedule, ~w(daily weekly monthly),
      message: "must be daily, weekly, or monthly"
    )
    |> foreign_key_constraint(:site_id)
    |> foreign_key_constraint(:created_by)
  end
end
