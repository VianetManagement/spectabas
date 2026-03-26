defmodule Spectabas.Reports do
  @moduledoc """
  Context for managing reports and data exports.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Reports.{Report, Export}

  @doc """
  Create a report for a site.
  """
  def create_report(site, user, attrs) do
    attrs =
      attrs
      |> Map.put(:site_id, site.id)
      |> Map.put(:created_by, user.id)

    %Report{}
    |> Report.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List all reports for a site.
  """
  def list_reports(site) do
    Repo.all(
      from(r in Report,
        where: r.site_id == ^site.id,
        order_by: [desc: r.inserted_at]
      )
    )
  end

  @doc """
  Create a data export for a site and enqueue the export worker.
  """
  def create_export(site, user, attrs) do
    export_attrs =
      attrs
      |> Map.put(:site_id, site.id)
      |> Map.put(:user_id, user.id)
      |> Map.put(:status, "pending")

    case %Export{} |> Export.changeset(export_attrs) |> Repo.insert() do
      {:ok, export} ->
        %{"export_id" => export.id}
        |> Spectabas.Workers.DataExport.new()
        |> Oban.insert()

        {:ok, export}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Mark an export as completed with the file path.
  """
  def mark_export_complete(%Export{} = export, file_path) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    export
    |> Export.changeset(%{
      status: "completed",
      file_path: file_path,
      completed_at: now
    })
    |> Repo.update()
  end

  @doc """
  Get a single export by ID. Raises if not found.
  """
  def get_export!(id), do: Repo.get!(Export, id)

  @doc """
  Mark an export as failed with an error message.
  """
  def mark_export_failed(%Export{} = export, error) do
    export
    |> Export.changeset(%{
      status: "failed",
      error: error
    })
    |> Repo.update()
  end
end
