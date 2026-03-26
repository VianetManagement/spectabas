defmodule Spectabas.Workers.DataExport do
  @moduledoc """
  Exports analytics data for a site to CSV. Re-fetches the Export, User,
  and Site from the database and verifies access at execution time.
  """

  use Oban.Worker, queue: :exports, max_attempts: 3

  require Logger

  alias Spectabas.{Accounts, ClickHouse, Repo}
  alias Spectabas.Reports
  alias Spectabas.Reports.Export

  @max_rows 1_000_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => export_id}}) do
    export = Repo.get!(Export, export_id) |> Repo.preload([:site, :user])

    with :ok <- verify_access(export),
         {:ok, rows} <- fetch_data(export),
         {:ok, file_path} <- write_csv(export, rows) do
      Reports.mark_export_complete(export, file_path)
      Logger.info("[DataExport] Export #{export_id} completed: #{file_path}")
      :ok
    else
      {:error, :unauthorized} ->
        Reports.mark_export_failed(export, "Unauthorized access")
        {:error, :unauthorized}

      {:error, reason} ->
        Reports.mark_export_failed(export, inspect(reason))
        {:error, reason}
    end
  end

  defp verify_access(%Export{user: user, site: site}) do
    if Accounts.can_access_site?(user, site) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp fetch_data(%Export{site: site, date_from: date_from, date_to: date_to}) do
    sql = """
    SELECT
      timestamp,
      event_type,
      url_path,
      url_host,
      referrer_domain,
      utm_source,
      utm_medium,
      utm_campaign,
      country,
      city,
      device_type,
      browser,
      os,
      visitor_id,
      session_id
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND timestamp >= #{ClickHouse.param(format_datetime(date_from))}
      AND timestamp <= #{ClickHouse.param(format_datetime(date_to))}
    ORDER BY timestamp ASC
    LIMIT #{@max_rows}
    """

    ClickHouse.query(sql)
  end

  defp write_csv(%Export{id: export_id}, rows) do
    file_path = Path.join(System.tmp_dir!(), "spectabas_export_#{export_id}.csv")

    headers = [
      "timestamp",
      "event_type",
      "url_path",
      "url_host",
      "referrer_domain",
      "utm_source",
      "utm_medium",
      "utm_campaign",
      "country",
      "city",
      "device_type",
      "browser",
      "os",
      "visitor_id",
      "session_id"
    ]

    csv_content =
      [headers | Enum.map(rows, fn row -> Enum.map(headers, &Map.get(row, &1, "")) end)]
      |> CSV.encode()
      |> Enum.join()

    File.write!(file_path, csv_content)
    {:ok, file_path}
  end

  defp format_datetime(nil), do: "1970-01-01 00:00:00"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end
