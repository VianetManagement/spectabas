defmodule Spectabas.Repo.Migrations.CreateSpamDomains do
  use Ecto.Migration

  def change do
    create table(:spam_domains) do
      add :domain, :string, null: false
      add :source, :string, default: "manual"
      add :hits_total, :integer, default: 0
      add :last_seen_at, :utc_datetime
      add :active, :boolean, default: true
      timestamps(type: :utc_datetime)
    end

    create unique_index(:spam_domains, [:domain])
  end
end
