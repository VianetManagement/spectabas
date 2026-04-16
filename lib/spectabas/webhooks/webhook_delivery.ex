defmodule Spectabas.Webhooks.WebhookDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  schema "webhook_deliveries" do
    field :site_id, :id
    field :visitor_id, :binary_id
    field :event_type, :string
    field :score, :integer
    field :signals, {:array, :string}, default: []
    field :http_status, :integer
    field :success, :boolean, default: false
    field :error_message, :string
    field :url, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :site_id,
      :visitor_id,
      :event_type,
      :score,
      :signals,
      :http_status,
      :success,
      :error_message,
      :url
    ])
    |> validate_required([:site_id, :event_type])
    |> validate_inclusion(:event_type, ["flag", "deactivate"])
  end
end
