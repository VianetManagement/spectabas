defmodule Spectabas.Workers.ConversionDetector do
  @moduledoc """
  Runs every 15 minutes per active site. Scans recent ClickHouse events
  + Stripe ecommerce_events for matches against configured conversion
  actions and writes Postgres `conversions` rows.

  Idempotent — `Conversion.dedup_key` ensures a re-run never double-counts.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled, :executing]]

  require Logger

  alias Spectabas.Conversions.Detectors
  alias Spectabas.Sites

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(_job) do
    sites =
      Sites.list_sites()
      |> Enum.filter(& &1.active)

    Enum.each(sites, fn site ->
      try do
        case Detectors.run_for_site(site) do
          0 -> :ok
          n -> Logger.notice("[ConversionDetector] site=#{site.id} new=#{n}")
        end
      rescue
        e ->
          Logger.warning("[ConversionDetector] site=#{site.id} crashed: #{Exception.message(e)}")
      end
    end)

    :ok
  end
end
