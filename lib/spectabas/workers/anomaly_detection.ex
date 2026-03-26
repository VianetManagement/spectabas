defmodule Spectabas.Workers.AnomalyDetection do
  @moduledoc """
  Compares current-hour pageviews against the 7-day hourly average
  for each active site. Sends alerts on >90% drop or >5x spike
  when the baseline average is above 10 pageviews per hour.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Spectabas.{ClickHouse, Sites, Notifications}

  @min_baseline 10
  @drop_threshold 0.1
  @spike_multiplier 5

  @impl Oban.Worker
  def perform(_job) do
    sites = Sites.list_sites()

    Enum.each(sites, fn site ->
      if site.active do
        check_site(site)
      end
    end)

    :ok
  end

  defp check_site(site) do
    with {:ok, current} <- current_hour_pageviews(site),
         {:ok, avg} <- seven_day_hourly_avg(site) do
      cond do
        avg < @min_baseline ->
          :ok

        current <= avg * @drop_threshold ->
          Logger.warning(
            "[Anomaly] Site #{site.id}: traffic drop. Current: #{current}, Avg: #{avg}"
          )

          Notifications.send_alert(site, :traffic_drop, %{
            current_pageviews: current,
            average_pageviews: avg,
            drop_percentage: round((1 - current / avg) * 100, 1)
          })

        current >= avg * @spike_multiplier ->
          Logger.warning(
            "[Anomaly] Site #{site.id}: traffic spike. Current: #{current}, Avg: #{avg}"
          )

          Notifications.send_alert(site, :traffic_spike, %{
            current_pageviews: current,
            average_pageviews: avg,
            spike_multiplier: round(current / avg, 1)
          })

        true ->
          :ok
      end
    else
      {:error, reason} ->
        Logger.error("[Anomaly] Failed to check site #{site.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp current_hour_pageviews(site) do
    sql = """
    SELECT count() AS pageviews
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND event_type = 'pageview'
      AND timestamp >= toStartOfHour(now())
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"pageviews" => count}]} -> {:ok, count}
      {:ok, []} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp seven_day_hourly_avg(site) do
    sql = """
    SELECT avg(hourly_count) AS avg_pageviews
    FROM (
      SELECT
        toStartOfHour(timestamp) AS hour,
        count() AS hourly_count
      FROM events
      WHERE site_id = #{ClickHouse.param(site.id)}
        AND event_type = 'pageview'
        AND timestamp >= now() - INTERVAL 7 DAY
        AND toHour(timestamp) = toHour(now())
      GROUP BY hour
    )
    """

    case ClickHouse.query(sql) do
      {:ok, [%{"avg_pageviews" => avg}]} when not is_nil(avg) -> {:ok, avg}
      {:ok, _} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp round(value, precision) when is_number(value) do
    Float.round(value / 1, precision)
  end
end
