defmodule Spectabas.Repo.Migrations.CreateWebhookDeliveries do
  use Ecto.Migration

  def change do
    create table(:webhook_deliveries) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :visitor_id, :binary_id
      add :event_type, :string, null: false
      add :score, :integer
      add :signals, {:array, :string}, default: []
      add :http_status, :integer
      add :success, :boolean, default: false, null: false
      add :error_message, :string
      add :url, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:webhook_deliveries, [:site_id, :inserted_at])
  end
end
