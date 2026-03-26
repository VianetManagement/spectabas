defmodule Spectabas.Accounts.AuditLog do
  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [updated_at: false]

  schema "audit_logs" do
    field :event, :string
    field :metadata, :map, default: %{}
    field :user_id, :id
    field :occurred_at, :utc_datetime

    timestamps()
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [:event, :metadata, :user_id, :occurred_at])
    |> validate_required([:event, :occurred_at])
    |> validate_length(:event, max: 255)
  end
end
