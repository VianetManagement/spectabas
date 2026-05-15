defmodule Spectabas.Logs.RenderPoller do
  @moduledoc """
  Pulls log lines from Render's REST API for every service configured
  on a site, normalizes them into `Spectabas.Logs` rows, and pushes
  them into the existing `Logs.IngestBuffer` (same buffer used by the
  HTTP and syslog ingest paths).

  ## Cursor semantics

  Each `(site, service_id)` pair has a high-water-mark stored in
  `sites.render_log_cursors` (JSONB map keyed by service ID). On each
  poll we fetch logs from that cursor forward, and after a successful
  pull update the cursor to the `nextStartTime` Render returned. If
  there's no cursor yet (newly-configured site), we start from
  `now() - 60s` so the first poll doesn't try to drain backlog.

  ## When this runs

  The Oban worker `Spectabas.Workers.RenderLogPoller` fires every
  minute via cron and calls `poll_site/1` for each site with
  `logs_enabled = true` and at least one configured service. The poll
  is best-effort: errors are logged but do not crash the worker, so
  one misconfigured site doesn't break ingest for the rest.
  """

  alias Spectabas.Logs
  alias Spectabas.Logs.{IngestBuffer, RenderAPI}
  alias Spectabas.{Repo, Sites}

  require Logger

  @initial_lookback_seconds 60

  @doc """
  Poll every configured service on `site`, push rows to the ingest
  buffer, and persist updated cursors. Returns
  `{:ok, %{total_logs: N, services: M}}` or `{:error, reason}`.
  """
  def poll_site(%{render_service_ids: ids} = site) when is_list(ids) and ids != [] do
    cursors = site.render_log_cursors || %{}

    {new_cursors, total_logs} =
      Enum.reduce(ids, {cursors, 0}, fn service_id, {curs, total} ->
        start_time = Map.get(curs, service_id) || initial_start_time()

        case RenderAPI.list_logs(site, service_id, start_time) do
          {:ok, %{logs: logs, next_start_time: next}} ->
            rows = Enum.map(logs, &log_to_row(&1, site.id))
            push_rows(rows)

            new_cursor = next || latest_timestamp(logs) || start_time
            {Map.put(curs, service_id, new_cursor), total + length(logs)}

          {:error, reason} ->
            Logger.warning(
              "[RenderPoller] site=#{site.id} service=#{service_id} fetch failed: #{inspect(reason)}"
            )

            {curs, total}
        end
      end)

    if new_cursors != cursors do
      Sites.update_render_cursors(site, new_cursors)
    end

    {:ok, %{total_logs: total_logs, services: length(ids)}}
  end

  def poll_site(_), do: {:ok, %{total_logs: 0, services: 0}}

  @doc """
  All sites currently eligible for Render-API polling: logs_enabled,
  has an API key, has an owner ID, has at least one service ID.
  """
  def eligible_sites do
    import Ecto.Query

    from(s in Sites.Site,
      where:
        s.logs_enabled == true and
          not is_nil(s.render_api_key_encrypted) and
          not is_nil(s.render_owner_id) and
          fragment("array_length(?, 1) > 0", s.render_service_ids)
    )
    |> Repo.all()
  end

  defp push_rows([]), do: :ok

  defp push_rows(rows) do
    if IngestBuffer.full?() do
      Logger.warning("[RenderPoller] ingest buffer full, dropping #{length(rows)} rows")
    else
      IngestBuffer.push_batch(Enum.reject(rows, &is_nil/1))
    end
  end

  defp log_to_row(%{"message" => msg, "timestamp" => ts} = log, site_id) do
    entry = %{
      "level" => infer_level(log),
      "message" => msg,
      "timestamp" => ts,
      "host" => RenderAPI.label(log, "host"),
      "source" => RenderAPI.label(log, "type")
    }

    Logs.parse_and_normalize(entry, site_id)
  end

  defp log_to_row(_, _), do: nil

  # Render's logs API returns a structured `level` label for some log
  # types (e.g. "info", "error") but not for app stdout. Use it when
  # present; otherwise let `Logs.parse_and_normalize/2` infer from the
  # message prefix.
  defp infer_level(%{"labels" => labels}) when is_list(labels) do
    case Enum.find(labels, fn
           %{"name" => "level"} -> true
           _ -> false
         end) do
      %{"value" => v} when is_binary(v) and byte_size(v) > 0 -> v
      _ -> ""
    end
  end

  defp infer_level(_), do: ""

  defp initial_start_time do
    DateTime.utc_now()
    |> DateTime.add(-@initial_lookback_seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp latest_timestamp([]), do: nil

  defp latest_timestamp(logs) do
    logs
    |> Enum.map(& &1["timestamp"])
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end
end
