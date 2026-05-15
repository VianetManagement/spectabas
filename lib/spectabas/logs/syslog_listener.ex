defmodule Spectabas.Logs.SyslogListener do
  @moduledoc """
  TLS-secured syslog (RFC 5424 over RFC 5425 framing) receiver. Render
  Log Streams — and every other syslog-style provider Render integrates
  with — push log lines over a TLS connection rather than HTTPS, so the
  HTTP `/c/logs` endpoint can't receive directly from Render. This
  listener fills that gap.

  ## Topology

  - One GenServer owns the listen socket
  - It spawns a dedicated acceptor process that loops on
    `:ssl.transport_accept` + `:ssl.handshake`
  - Each accepted connection is handed to a fresh long-lived
    `Task.Supervisor` child that owns the socket and reads frames

  ## Auth

  Customers configure Render's Log Stream with `Token` = their site's
  `logs_token`. The parser pulls that token out of the structured-data
  block or the message prefix and we look up the site by token.

  ## Config (env vars, read at startup)

      SYSLOG_LISTEN_PORT   — required to enable. Typical: 6514
      SYSLOG_TLS_CERT_FILE — PEM cert chain on disk
      SYSLOG_TLS_KEY_FILE  — PEM private key on disk

  If `SYSLOG_LISTEN_PORT` is unset, this child isn't started at all
  (the listener does nothing in tests / dev).
  """

  use GenServer
  require Logger

  alias Spectabas.Logs
  alias Spectabas.Logs.{IngestBuffer, SyslogParser}

  @recv_timeout_ms 60_000
  @max_buffer_bytes 1_048_576

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the listener is configured to start (port + cert + key present)."
  def enabled? do
    port = System.get_env("SYSLOG_LISTEN_PORT")
    cert = System.get_env("SYSLOG_TLS_CERT_FILE")
    key = System.get_env("SYSLOG_TLS_KEY_FILE")
    port not in [nil, ""] and cert not in [nil, ""] and key not in [nil, ""]
  end

  @impl true
  def init(_opts) do
    port = String.to_integer(System.get_env("SYSLOG_LISTEN_PORT"))
    cert_file = System.get_env("SYSLOG_TLS_CERT_FILE")
    key_file = System.get_env("SYSLOG_TLS_KEY_FILE")

    ssl_opts = [
      certfile: cert_file,
      keyfile: key_file,
      reuseaddr: true,
      mode: :binary,
      active: false,
      packet: 0,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]

    case :ssl.listen(port, ssl_opts) do
      {:ok, lsock} ->
        Logger.notice("[SyslogListener] listening on TLS port #{port}")
        acceptor = spawn_link(fn -> accept_loop(lsock) end)
        {:ok, %{lsock: lsock, port: port, acceptor: acceptor}}

      {:error, reason} ->
        Logger.error("[SyslogListener] failed to bind port #{port}: #{inspect(reason)}")
        {:stop, {:listen_failed, reason}}
    end
  end

  defp accept_loop(lsock) do
    case :ssl.transport_accept(lsock) do
      {:ok, sock} ->
        case :ssl.handshake(sock, 10_000) do
          {:ok, sslsock} ->
            spawn_connection(sslsock)

          {:error, reason} ->
            Logger.debug("[SyslogListener] handshake failed: #{inspect(reason)}")
            :ssl.close(sock)
        end

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[SyslogListener] accept error: #{inspect(reason)}")
    end

    accept_loop(lsock)
  end

  defp spawn_connection(sslsock) do
    {:ok, pid} =
      Task.Supervisor.start_child(Spectabas.IngestFlushSupervisor, fn ->
        connection_loop(sslsock, <<>>, %{})
      end)

    case :ssl.controlling_process(sslsock, pid) do
      :ok -> :ok
      {:error, reason} -> Logger.debug("[SyslogListener] cp transfer: #{inspect(reason)}")
    end
  end

  defp connection_loop(sslsock, buffer, site_cache) do
    case :ssl.recv(sslsock, 0, @recv_timeout_ms) do
      {:ok, chunk} ->
        new_buf = buffer <> chunk

        if byte_size(new_buf) > @max_buffer_bytes do
          Logger.warning(
            "[SyslogListener] dropping connection: buffer exceeded #{@max_buffer_bytes} bytes"
          )

          :ssl.close(sslsock)
        else
          {frames, remainder} = SyslogParser.decode_frames(new_buf)
          site_cache = process_frames(frames, site_cache)
          connection_loop(sslsock, remainder, site_cache)
        end

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        :ssl.close(sslsock)

      {:error, reason} ->
        Logger.debug("[SyslogListener] recv error: #{inspect(reason)}")
        :ssl.close(sslsock)
    end
  end

  defp process_frames([], site_cache), do: site_cache

  defp process_frames(frames, site_cache) do
    {rows, site_cache} =
      Enum.reduce(frames, {[], site_cache}, fn frame, {rows, cache} ->
        case SyslogParser.parse(frame) do
          {:ok, parsed} ->
            case resolve_site_id(parsed.token, cache) do
              {nil, cache} ->
                {rows, cache}

              {site_id, cache} ->
                row = build_row(parsed, site_id, frame)
                {[row | rows], cache}
            end

          {:error, _reason} ->
            {rows, cache}
        end
      end)

    if rows != [] do
      if IngestBuffer.full?() do
        Logger.warning("[SyslogListener] buffer full, dropping #{length(rows)} rows")
      else
        IngestBuffer.push_batch(Enum.reverse(rows))
      end
    end

    site_cache
  end

  defp resolve_site_id(nil, cache), do: {nil, cache}
  defp resolve_site_id("", cache), do: {nil, cache}

  defp resolve_site_id(token, cache) do
    case Map.fetch(cache, token) do
      {:ok, site_id} ->
        {site_id, cache}

      :error ->
        case Logs.site_by_token(token) do
          %{id: id, logs_enabled: true} ->
            {id, Map.put(cache, token, id)}

          _ ->
            {nil, Map.put(cache, token, nil)}
        end
    end
  end

  defp build_row(parsed, site_id, raw_frame) do
    entry = %{
      "level" => parsed.level,
      "message" => parsed.message,
      "timestamp" => DateTime.to_iso8601(parsed.timestamp),
      "host" => parsed.hostname,
      "source" => parsed.app_name
    }

    case Logs.parse_and_normalize(entry, site_id) do
      nil -> nil
      row -> %{row | raw_payload: truncate(raw_frame, 16_000)}
    end
  end

  defp truncate(bin, max) when byte_size(bin) > max, do: binary_part(bin, 0, max)
  defp truncate(bin, _), do: bin

  @impl true
  def terminate(_reason, %{lsock: lsock}) do
    :ssl.close(lsock)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
