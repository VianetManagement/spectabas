defmodule SpectabasWeb.Dashboard.DateHelpers do
  @moduledoc "Shared date range helpers for dashboard LiveViews."

  def range_to_period("24h"), do: :day
  def range_to_period("7d"), do: :week
  def range_to_period("30d"), do: :month
  def range_to_period("90d"), do: :quarter
  def range_to_period(_), do: :week
end
