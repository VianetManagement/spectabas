defmodule Spectabas.Repo.Migrations.CreateAsnOverrides do
  use Ecto.Migration

  def change do
    create table(:asn_overrides) do
      add :asn_number, :integer, null: false
      add :asn_org, :string, default: ""
      add :classification, :string, null: false
      add :source, :string, null: false, default: "auto"
      add :reason, :text
      add :auto_evidence, :map
      add :active, :boolean, default: true, null: false
      add :backfill_submitted, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:asn_overrides, [:asn_number, :classification],
             where: "active = true",
             name: :asn_overrides_active_unique
           )

    create index(:asn_overrides, [:classification])
    create index(:asn_overrides, [:source])
    create index(:asn_overrides, [:inserted_at])
  end
end
