defmodule Spectabas.Workers.SessionCleanup do
  @moduledoc """
  Closes stale sessions that have been idle for more than 30 minutes.
  Uses batch UPDATE queries instead of loading all sessions into memory.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Sessions.Session
  require Logger

  @idle_threshold_minutes 30

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    threshold = DateTime.add(now, -@idle_threshold_minutes * 60, :second)

    # Batch update: close stale sessions with single pageview (bounces)
    {bounce_count, _} =
      from(s in Session,
        where: is_nil(s.ended_at),
        where: s.updated_at < ^threshold,
        where: s.pageview_count <= 1
      )
      |> Repo.update_all(set: [ended_at: now, is_bounce: true])

    # Batch update: close stale sessions with multiple pageviews
    # Duration is approximated as (now - started_at) since we don't have
    # the exact last activity time in a batch update context
    {non_bounce_count, _} =
      from(s in Session,
        where: is_nil(s.ended_at),
        where: s.updated_at < ^threshold,
        where: s.pageview_count > 1
      )
      |> Repo.update_all(set: [ended_at: now, is_bounce: false])

    total = bounce_count + non_bounce_count

    if total > 0 do
      Logger.info("[SessionCleanup] Closed #{total} stale sessions (#{bounce_count} bounces)")
    end

    :ok
  end
end
