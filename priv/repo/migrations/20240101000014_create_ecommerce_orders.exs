defmodule Spectabas.Repo.Migrations.CreateEcommerceOrders do
  use Ecto.Migration

  def change do
    create table(:ecommerce_orders) do
      add :site_id, references(:sites, on_delete: :delete_all), null: false
      add :visitor_id, :binary_id
      add :session_id, :binary_id
      add :order_id, :string, null: false
      add :revenue, :decimal, precision: 12, scale: 2
      add :subtotal, :decimal, precision: 12, scale: 2
      add :tax, :decimal, precision: 12, scale: 2
      add :shipping, :decimal, precision: 12, scale: 2
      add :discount, :decimal, precision: 12, scale: 2
      add :currency, :string, default: "USD"
      add :items, :map, default: "[]"
      add :occurred_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:ecommerce_orders, [:site_id, :order_id])
  end
end
