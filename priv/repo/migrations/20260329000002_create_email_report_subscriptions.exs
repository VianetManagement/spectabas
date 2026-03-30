defmodule Spectabas.Repo.Migrations.CreateEmailReportSubscriptions do
  use Ecto.Migration

  def change do
    create table(:email_report_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :frequency, :string, null: false, default: "off"
      add :send_hour, :integer, default: 9
      add :last_sent_at, :utc_datetime
      add :last_period_key, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:email_report_subscriptions, [:user_id, :site_id])
    create index(:email_report_subscriptions, [:site_id])
  end
end
