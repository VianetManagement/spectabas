defmodule Spectabas.Workers.ScheduledReports do
  @moduledoc """
  Fetches reports that are due based on their schedule and enqueues
  DataExport jobs for each.
  """

  use Oban.Worker, queue: :reports, max_attempts: 3

  require Logger

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Reports
  alias Spectabas.Reports.Report

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    threshold = schedule_threshold(now)

    due_reports =
      from(r in Report,
        where: r.active == true,
        where: not is_nil(r.schedule),
        where: is_nil(r.last_sent_at) or r.last_sent_at <= ^threshold
      )
      |> Repo.all()
      |> Enum.filter(&report_due?(&1, now))

    Enum.each(due_reports, fn report ->
      report = Repo.preload(report, [:site])

      date_range = compute_date_range(report.schedule, now)

      case Reports.create_export(report.site, %{id: report.created_by}, %{
             format: "csv",
             date_from: date_range.from,
             date_to: date_range.to
           }) do
        {:ok, _export} ->
          report
          |> Ecto.Changeset.change(last_sent_at: now)
          |> Repo.update()

          Logger.info("[ScheduledReports] Enqueued export for report #{report.id}")

        {:error, reason} ->
          Logger.error(
            "[ScheduledReports] Failed to create export for report #{report.id}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp report_due?(%Report{schedule: schedule, last_sent_at: nil}, _now)
       when not is_nil(schedule),
       do: true

  defp report_due?(%Report{schedule: "daily", last_sent_at: last}, now) do
    DateTime.diff(now, last, :hour) >= 24
  end

  defp report_due?(%Report{schedule: "weekly", last_sent_at: last}, now) do
    DateTime.diff(now, last, :hour) >= 168
  end

  defp report_due?(%Report{schedule: "monthly", last_sent_at: last}, now) do
    DateTime.diff(now, last, :hour) >= 720
  end

  defp report_due?(_, _), do: false

  defp schedule_threshold(now) do
    # Return a threshold that's far enough in the past to catch all due reports
    DateTime.add(now, -30 * 24 * 3600, :second)
  end

  defp compute_date_range("daily", now) do
    from = DateTime.add(now, -24 * 3600, :second)
    %{from: from, to: now}
  end

  defp compute_date_range("weekly", now) do
    from = DateTime.add(now, -7 * 24 * 3600, :second)
    %{from: from, to: now}
  end

  defp compute_date_range("monthly", now) do
    from = DateTime.add(now, -30 * 24 * 3600, :second)
    %{from: from, to: now}
  end

  defp compute_date_range(_, now) do
    from = DateTime.add(now, -24 * 3600, :second)
    %{from: from, to: now}
  end
end
