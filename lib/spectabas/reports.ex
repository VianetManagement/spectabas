defmodule Spectabas.Reports do
  @moduledoc """
  Context for managing reports and data exports.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Reports.{Report, Export, EmailReportSubscription}

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

  # --- Email Report Subscriptions ---

  @doc "Get or create an email report subscription for a user+site."
  def upsert_email_subscription(user, site, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("user_id", user.id)
      |> Map.put("site_id", site.id)

    %EmailReportSubscription{}
    |> EmailReportSubscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:frequency, :send_hour, :updated_at]},
      conflict_target: [:user_id, :site_id],
      returning: true
    )
  end

  @doc "Get a user's email report subscription for a site."
  def get_email_subscription(user, site) do
    Repo.one(
      from(s in EmailReportSubscription,
        where: s.user_id == ^user.id and s.site_id == ^site.id
      )
    )
  end

  @doc "Get a subscription by ID with preloads."
  def get_email_subscription!(id) do
    Repo.get!(EmailReportSubscription, id) |> Repo.preload([:user, :site])
  end

  @doc "List all active subscriptions for a site (for admin view)."
  def list_email_subscriptions_for_site(site) do
    Repo.all(
      from(s in EmailReportSubscription,
        where: s.site_id == ^site.id and s.frequency != :off,
        preload: [:user],
        order_by: [asc: :inserted_at]
      )
    )
  end

  @doc "Find subscriptions due for sending right now."
  def list_due_subscriptions(utc_now) do
    from(s in EmailReportSubscription,
      where: s.frequency != :off,
      preload: [:user, :site]
    )
    |> Repo.all()
    |> Enum.filter(fn sub ->
      tz = (sub.site && sub.site.timezone) || "UTC"

      case DateTime.shift_zone(utc_now, tz) do
        {:ok, local_now} ->
          local_now.hour == sub.send_hour and
            period_key(sub.frequency, local_now) != sub.last_period_key

        _ ->
          false
      end
    end)
  end

  @doc "Mark a subscription as sent for the current period."
  def mark_subscription_sent(sub, period_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    sub
    |> Ecto.Changeset.change(last_sent_at: now, last_period_key: period_key)
    |> Repo.update()
  end

  @doc "Unsubscribe (set frequency to off)."
  def unsubscribe(subscription_id) do
    case Repo.get(EmailReportSubscription, subscription_id) do
      nil -> {:error, :not_found}
      sub -> sub |> Ecto.Changeset.change(frequency: :off) |> Repo.update()
    end
  end

  @doc "Compute period key for idempotent sending."
  def period_key(:daily, local_now) do
    Date.to_iso8601(DateTime.to_date(local_now))
  end

  def period_key(:weekly, local_now) do
    date = DateTime.to_date(local_now)
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    "#{year}-W#{String.pad_leading(to_string(week), 2, "0")}"
  end

  def period_key(:monthly, local_now) do
    "#{local_now.year}-#{String.pad_leading(to_string(local_now.month), 2, "0")}"
  end

  def period_key(_, _), do: nil
end
