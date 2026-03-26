defmodule Spectabas.Workers.SessionCleanup do
  @moduledoc """
  Closes stale sessions that have been idle for more than 30 minutes.
  Sets ended_at to now and marks as bounce if only 1 pageview.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Sessions.Session

  @idle_threshold_minutes 30

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    threshold = DateTime.add(now, -@idle_threshold_minutes * 60, :second)

    stale_sessions =
      from(s in Session,
        where: is_nil(s.ended_at),
        where: s.updated_at < ^threshold
      )
      |> Repo.all()

    Enum.each(stale_sessions, fn session ->
      duration = DateTime.diff(now, session.started_at, :second)

      session
      |> Session.changeset(%{
        ended_at: now,
        duration_s: max(duration, 0),
        is_bounce: (session.pageview_count || 0) <= 1
      })
      |> Repo.update()
    end)

    :ok
  end
end
