defmodule Spectabas.Repo.Migrations.CreateSites do
  use Ecto.Migration

  def change do
    create table(:sites) do
      add :name, :string, null: false
      add :domain, :string, null: false
      add :public_key, :string, null: false
      add :timezone, :string, default: "UTC"
      add :retention_days, :integer, default: 365
      add :active, :boolean, default: true
      add :dns_verified, :boolean, default: false
      add :dns_verified_at, :utc_datetime
      add :gdpr_mode, :string, default: "on", null: false
      add :cookie_domain, :string
      add :cross_domain_tracking, :boolean, default: false
      add :cross_domain_sites, {:array, :string}, default: []
      add :ecommerce_enabled, :boolean, default: false
      add :currency, :string, default: "USD"
      add :ip_allowlist, {:array, :string}, default: []
      add :ip_blocklist, {:array, :string}, default: []

      timestamps()
    end

    create unique_index(:sites, [:domain])
    create unique_index(:sites, [:public_key])
  end
end
