defmodule Spectabas.Workers.RenderLogPoller do
  @moduledoc """
  Polls Render's REST Logs API every minute for every site that has
  `logs_enabled = true` and Render credentials configured. New log
  lines get pushed into the existing `Logs.IngestBuffer` — same path
  the HTTP + syslog ingest endpoints feed.

  One site failing (bad API key, revoked credentials, Render outage)
  must not stop other sites from polling, so the per-site call is
  wrapped in a try/rescue + logged.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 30, states: [:available, :executing, :scheduled, :retryable]]

  require Logger

  alias Spectabas.Logs.RenderPoller

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(50)

  @impl Oban.Worker
  def perform(_job) do
    sites = RenderPoller.eligible_sites()

    Enum.each(sites, fn site ->
      try do
        case RenderPoller.poll_site(site) do
          {:ok, %{total_logs: 0}} ->
            :ok

          {:ok, %{total_logs: n, services: svc}} ->
            Logger.info(
              "[RenderLogPoller] site=#{site.id} ingested #{n} logs from #{svc} services"
            )
        end
      rescue
        e ->
          Logger.warning("[RenderLogPoller] site=#{site.id} crashed: #{Exception.message(e)}")
      end
    end)

    :ok
  end
end
