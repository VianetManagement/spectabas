defmodule Spectabas.Workers.EmailReportDispatcher do
  @moduledoc "Finds email report subscriptions due for sending and enqueues delivery jobs."

  use Oban.Worker, queue: :reports, max_attempts: 1
  require Logger

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    due = Spectabas.Reports.list_due_subscriptions(now)

    if due != [] do
      Logger.info("[EmailReports] Dispatching #{length(due)} report emails")
    end

    Enum.each(due, fn sub ->
      %{subscription_id: sub.id}
      |> Spectabas.Workers.EmailReportDelivery.new()
      |> Oban.insert()
    end)

    :ok
  end
end
