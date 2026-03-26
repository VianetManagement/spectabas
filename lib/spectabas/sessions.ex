defmodule Spectabas.Sessions do
  @moduledoc """
  Session management context. Resolves sessions from an ETS cache,
  creating new ones or extending existing ones based on visitor activity.

  Sessions expire after 30 minutes of inactivity.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Sessions.{Session, SessionCache}

  @session_timeout_ms 30 * 60 * 1000
  @active_threshold_s 300

  @doc """
  Resolve a session for the given site_id and visitor_id.
  Checks the ETS cache first; opens a new session or extends
  an existing one.

  `event_data` should contain keys: entry_url, referrer, country, city,
  device_type, browser, os.

  Returns `{:ok, %Session{}}` or `{:error, reason}`.
  """
  def resolve(site_id, visitor_id, event_data) do
    cache_key = {site_id, visitor_id}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case SessionCache.get(cache_key) do
      {:ok, session_id, last_activity} ->
        if expired?(last_activity, now) do
          create_session(site_id, visitor_id, event_data, now)
        else
          extend_session(session_id, event_data, now)
        end

      :miss ->
        create_session(site_id, visitor_id, event_data, now)
    end
  end

  @doc """
  Close a session by setting ended_at and calculating duration.
  """
  def close_session(%Session{} = session) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    duration = DateTime.diff(now, session.started_at, :second)

    session
    |> Session.changeset(%{
      ended_at: now,
      duration_s: max(duration, 0)
    })
    |> Repo.update()
  end

  def close_session(session_id) when is_binary(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> close_session(session)
    end
  end

  @doc """
  Get count of active sessions for a site (active in last 5 minutes).
  """
  def get_active_count(site_id) do
    threshold =
      DateTime.utc_now()
      |> DateTime.add(-@active_threshold_s, :second)
      |> DateTime.truncate(:second)

    from(s in Session,
      where: s.site_id == ^site_id,
      where: s.started_at >= ^threshold or (is_nil(s.ended_at) and s.updated_at >= ^threshold),
      select: count(s.id, :distinct)
    )
    |> Repo.one()
  end

  # --- Private ---

  defp create_session(site_id, visitor_id, event_data, now) do
    attrs = %{
      site_id: site_id,
      visitor_id: visitor_id,
      started_at: now,
      pageview_count: 1,
      entry_url: event_data[:entry_url],
      exit_url: event_data[:entry_url],
      referrer: event_data[:referrer],
      country: event_data[:country],
      city: event_data[:city],
      device_type: event_data[:device_type],
      browser: event_data[:browser],
      os: event_data[:os],
      is_bounce: true
    }

    case %Session{} |> Session.changeset(attrs) |> Repo.insert() do
      {:ok, session} ->
        SessionCache.put({site_id, visitor_id}, session.id, now)
        {:ok, session}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp extend_session(session_id, event_data, now) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        duration = DateTime.diff(now, session.started_at, :second)
        new_count = (session.pageview_count || 0) + 1

        session
        |> Session.changeset(%{
          exit_url: event_data[:entry_url] || session.exit_url,
          pageview_count: new_count,
          duration_s: max(duration, 0),
          is_bounce: new_count <= 1
        })
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            SessionCache.touch({session.site_id, session.visitor_id}, now)
            {:ok, updated}

          error ->
            error
        end
    end
  end

  defp expired?(last_activity, now) do
    diff_ms = DateTime.diff(now, last_activity, :millisecond)
    diff_ms > @session_timeout_ms
  end
end
