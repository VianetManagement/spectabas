defmodule Spectabas.Ecommerce do
  @moduledoc """
  Context for recording and querying ecommerce orders.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Ecommerce.EcommerceOrder
  alias Spectabas.Analytics

  @doc """
  Record an order for a site. Upserts by site_id + order_id.
  """
  def record_order(site, attrs) do
    attrs = Map.put(attrs, :site_id, site.id)

    %EcommerceOrder{}
    |> EcommerceOrder.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :site_id, :order_id, :inserted_at]},
      conflict_target: [:site_id, :order_id]
    )
  end

  @doc """
  Get revenue statistics for a site and date range.
  Delegates to Analytics.ecommerce_stats/3.
  """
  def revenue_stats(site, user, date_range) do
    Analytics.ecommerce_stats(site, user, date_range)
  end
end
