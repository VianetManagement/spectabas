defmodule Spectabas.Reports.EmailReportSubscription do
  @moduledoc "Per-user, per-site email report preference."

  use Ecto.Schema
  import Ecto.Changeset

  schema "email_report_subscriptions" do
    belongs_to :user, Spectabas.Accounts.User
    belongs_to :site, Spectabas.Sites.Site

    field :frequency, Ecto.Enum, values: [:off, :daily, :weekly, :monthly], default: :off
    field :send_hour, :integer, default: 9
    field :last_sent_at, :utc_datetime
    field :last_period_key, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:user_id, :site_id, :frequency, :send_hour])
    |> validate_required([:user_id, :site_id, :frequency])
    |> validate_inclusion(:frequency, [:off, :daily, :weekly, :monthly])
    |> validate_number(:send_hour, greater_than_or_equal_to: 0, less_than: 24)
    |> unique_constraint([:user_id, :site_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:site_id)
  end
end
