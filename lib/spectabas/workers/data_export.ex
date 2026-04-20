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

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(120)

  @max_rows 1_000_000

  @chunk_size 10_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => export_id}}) do
    export = Repo.get!(Export, export_id) |> Repo.preload([:site, :user])

    with :ok <- verify_access(export),
         {:ok, file_path} <- stream_csv(export) do
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

  @csv_headers [
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

  defp stream_csv(%Export{id: export_id, site: site, date_from: date_from, date_to: date_to}) do
    # Build CSV in memory, then upload to R2 or write to /tmp
    header_csv = [@csv_headers] |> CSV.encode() |> Enum.join()

    case fetch_all_chunks(site, date_from, date_to, 0, 0, [header_csv]) do
      {:ok, parts} ->
        csv_body = IO.iodata_to_binary(parts)
        r2_key = "exports/#{export_id}.csv"

        if Spectabas.R2.configured?() do
          case Spectabas.R2.upload(r2_key, csv_body, "text/csv") do
            :ok -> {:ok, "r2://#{r2_key}"}
            {:error, reason} -> {:error, reason}
          end
        else
          file_path = Path.join(System.tmp_dir!(), "spectabas_export_#{export_id}.csv")
          File.write!(file_path, csv_body)
          {:ok, file_path}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_all_chunks(site, date_from, date_to, offset, total_written, acc) do
    if total_written >= @max_rows do
      {:ok, Enum.reverse(acc)}
    else
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
      LIMIT #{@chunk_size} OFFSET #{offset}
      """

      case ClickHouse.query(sql) do
        {:ok, []} ->
          {:ok, Enum.reverse(acc)}

        {:ok, rows} ->
          chunk_csv =
            rows
            |> Enum.map(fn row -> Enum.map(@csv_headers, &Map.get(row, &1, "")) end)
            |> CSV.encode()
            |> Enum.join()

          if length(rows) < @chunk_size do
            {:ok, Enum.reverse([chunk_csv | acc])}
          else
            fetch_all_chunks(
              site,
              date_from,
              date_to,
              offset + @chunk_size,
              total_written + length(rows),
              [chunk_csv | acc]
            )
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp format_datetime(nil), do: "1970-01-01 00:00:00"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end
