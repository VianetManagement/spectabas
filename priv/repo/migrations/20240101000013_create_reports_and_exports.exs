defmodule Spectabas.Repo.Migrations.CreateReportsAndExports do
  use Ecto.Migration

  def change do
    create table(:reports) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :created_by, references(:users, on_delete: :nilify_all)
      add :name, :string, null: false
      add :description, :string
      add :definition, :map, null: false, default: %{}
      add :schedule, :string
      add :recipients, {:array, :string}, default: []
      add :last_sent_at, :utc_datetime
      add :active, :boolean, default: true

      timestamps()
    end

    create table(:exports) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :format, :string, null: false, default: "csv"
      add :date_from, :utc_datetime
      add :date_to, :utc_datetime
      add :status, :string, default: "pending"
      add :file_path, :string
      add :error, :string
      add :completed_at, :utc_datetime

      timestamps()
    end
  end
end
