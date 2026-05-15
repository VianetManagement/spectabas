defmodule Spectabas.Logs do
  @moduledoc """
  Server-log ingest + query context. Customers ship Render Log Streams
  (or any log source) to `POST /c/logs` and we store them in the
  ClickHouse `server_logs` table with site-scoped retention.

  The pitch isn't "Spectabas does log management" — it's
  "logs are a dimension of your analytics." Cross-reference with
  pageviews, conversions, scraper detection, ad spend (v6.10.54+).

  ## Ingest pipeline

      1. Customer's log shipper POSTs to /c/logs with a Bearer token
         (the site's `logs_token`).
      2. `LogsController` authenticates, parses the body (Render
         Log Stream format or generic `{logs: [...]}`), validates,
         and hands each line to `parse_and_normalize/2`.
      3. Parser extracts level + message + Elixir error context
         (module / line / fingerprint) where applicable.
      4. Normalized rows go through `Spectabas.LogsIngestBuffer` —
         same pattern as the events `IngestBuffer`. Batches of 500
         flush async to CH.

  ## Retention

  CH-side TTL is fixed at 30 days on the `server_logs` table.
  Per-site retention is clamped at query time via
  `WHERE timestamp >= now() - INTERVAL site.logs_retention_days DAY`.
  Sites can set 1..30 in Site Settings.

  ## Error fingerprinting

  Elixir log lines matching `** (ErrorType) ...` get parsed for the
  error module, the originating line, and a SHA256 fingerprint of the
  normalized message. The fingerprint groups errors across instances
  so we can show "this error fired 47 times in the last hour" without
  scanning the full payload at query time.
  """

  alias Spectabas.ClickHouse
  require Logger

  @doc """
  Parse + normalize a single log line into a row map ready for batch
  insert. Accepts either a Render Log Stream entry shape (map with
  string keys) or our own normalized shape (map with atom keys).
  Returns nil if the entry is unparseable.
  """
  def parse_and_normalize(raw, site_id) when is_map(raw) and is_integer(site_id) do
    message = pick_message(raw)
    level = pick_level(raw)
    timestamp = pick_timestamp(raw)
    source = pick_source(raw)
    host = pick_host(raw)

    {fingerprint, error_module, error_line} = fingerprint_elixir_error(message, level)

    %{
      site_id: site_id,
      timestamp: timestamp,
      level: level,
      message: truncate(message, 8_000),
      source: truncate(source, 100),
      host: truncate(host, 200),
      request_id: truncate(pick_request_id(raw, message), 100),
      error_fingerprint: fingerprint,
      elixir_error_module: truncate(error_module, 200),
      elixir_error_line: error_line,
      raw_payload: truncate(Jason.encode!(raw), 16_000)
    }
  rescue
    e ->
      Logger.warning("[Logs] parse_and_normalize failed: #{Exception.message(e)}")
      nil
  end

  def parse_and_normalize(_, _), do: nil

  # ---- Field extraction (handle multiple input shapes) ----

  defp pick_message(%{"message" => m}) when is_binary(m), do: m
  defp pick_message(%{"msg" => m}) when is_binary(m), do: m
  defp pick_message(%{"log" => m}) when is_binary(m), do: m
  defp pick_message(other) when is_map(other), do: Jason.encode!(other)
  defp pick_message(_), do: ""

  defp pick_level(%{"level" => l}) when is_binary(l), do: normalize_level(l)
  defp pick_level(%{"severity" => l}) when is_binary(l), do: normalize_level(l)
  # Fallback: parse leading bracketed level from common Elixir/Phoenix logs.
  defp pick_level(%{"message" => m}) when is_binary(m), do: parse_level_from_message(m)
  defp pick_level(_), do: "info"

  defp normalize_level(l) do
    case String.downcase(l) do
      l when l in ~w(info notice warn warning error debug critical) -> l
      "err" -> "error"
      "fatal" -> "critical"
      _ -> "info"
    end
  end

  defp parse_level_from_message(msg) do
    cond do
      msg =~ ~r/^\[?error\]?\b/i -> "error"
      msg =~ ~r/^\[?warn(ing)?\]?\b/i -> "warning"
      msg =~ ~r/^\[?critical\]?\b/i -> "critical"
      msg =~ ~r/^\[?debug\]?\b/i -> "debug"
      msg =~ ~r/^\[?notice\]?\b/i -> "notice"
      msg =~ ~r/^\*\* \(/ -> "error"
      true -> "info"
    end
  end

  defp pick_timestamp(%{"timestamp" => t}) when is_binary(t), do: parse_timestamp(t)
  defp pick_timestamp(%{"time" => t}) when is_binary(t), do: parse_timestamp(t)
  defp pick_timestamp(%{"@timestamp" => t}) when is_binary(t), do: parse_timestamp(t)
  defp pick_timestamp(_), do: DateTime.utc_now()

  defp parse_timestamp(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp pick_source(%{"source" => s}) when is_binary(s), do: s
  defp pick_source(%{"servicePrefix" => s}) when is_binary(s), do: s
  defp pick_source(%{"service" => s}) when is_binary(s), do: s
  defp pick_source(_), do: ""

  defp pick_host(%{"host" => h}) when is_binary(h), do: h
  defp pick_host(%{"instance" => h}) when is_binary(h), do: h
  defp pick_host(_), do: ""

  defp pick_request_id(%{"request_id" => r}, _) when is_binary(r), do: r
  defp pick_request_id(%{"req_id" => r}, _) when is_binary(r), do: r

  defp pick_request_id(_, message) when is_binary(message) do
    case Regex.run(~r/request_id=([A-Za-z0-9_\-]+)/, message) do
      [_, id] -> id
      _ -> ""
    end
  end

  defp pick_request_id(_, _), do: ""

  # ---- Error fingerprinting ----

  @doc false
  def fingerprint_elixir_error(message, level) when is_binary(message) do
    cond do
      level in ["error", "critical"] ->
        do_fingerprint(message)

      message =~ ~r/^\*\* \(/ ->
        do_fingerprint(message)

      true ->
        {"", "", 0}
    end
  end

  def fingerprint_elixir_error(_, _), do: {"", "", 0}

  defp do_fingerprint(message) do
    {error_module, error_line} = extract_error_location(message)
    normalized = normalize_message_for_fingerprint(message)

    fp =
      :crypto.hash(:sha256, normalized)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    {fp, error_module, error_line}
  end

  # Strips variable bits (UUIDs, IDs, timestamps, hex strings) so the
  # same error from different requests fingerprints to the same hash.
  defp normalize_message_for_fingerprint(msg) do
    msg
    |> String.replace(~r/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.\d+]*Z?/, "<ts>")
    |> String.replace(
      ~r/\b[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\b/i,
      "<uuid>"
    )
    # 3+ digit standalone numbers → <id>. Covers most site / user / order
    # IDs without touching small literals like HTTP 200 codes that should
    # stay part of the fingerprint.
    |> String.replace(~r/\b\d{3,}\b/, "<id>")
    |> String.replace(~r/\b0x[a-f0-9]+\b/i, "<hex>")
    |> String.replace(~r/\bpid=<\d+\.\d+\.\d+>/, "pid=<pid>")
    |> String.replace(~r/#PID<\d+\.\d+\.\d+>/, "<pid>")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Pull the first frame from the Elixir stack trace. Standard format:
  #
  #     (app_name 6.10.53) lib/path/file.ex:42: ModuleName.fun/1
  #
  # We return the app name + line number so errors group by location.
  defp extract_error_location(msg) do
    lines = String.split(msg, "\n")

    Enum.find_value(lines, {"", 0}, fn line ->
      case Regex.run(~r/\(([A-Za-z_][A-Za-z0-9_]*)\s+[\d\.]+\)\s+\S+:(\d+):/, line) do
        [_, app, line_no] ->
          {app, String.to_integer(line_no)}

        _ ->
          nil
      end
    end)
  end

  defp truncate(s, max) when is_binary(s) and byte_size(s) > max,
    do: binary_part(s, 0, max)

  defp truncate(s, _) when is_binary(s), do: s
  defp truncate(_, _), do: ""

  # ---- Insert ----

  @doc """
  Insert a list of normalized rows (from `parse_and_normalize/2`) into
  the CH server_logs table. Caller is the batch-flush path in
  `LogsIngestBuffer` — callers shouldn't write rows synchronously
  per-request.
  """
  def insert_batch([]), do: :ok

  def insert_batch(rows) when is_list(rows) do
    ClickHouse.insert("server_logs", rows)
  end

  # ---- Site lookup by token ----

  @doc """
  Resolve a logs-ingest bearer token to a site (or nil). Used by the
  /c/logs controller for auth.
  """
  def site_by_token(nil), do: nil
  def site_by_token(""), do: nil

  def site_by_token(token) when is_binary(token) do
    Spectabas.Repo.get_by(Spectabas.Sites.Site, logs_token: token)
  end

  @doc """
  Generate a new logs token for a site. Cryptographically random
  base32-encoded string, 32 chars.
  """
  def generate_token do
    :crypto.strong_rand_bytes(20) |> Base.encode32(case: :lower, padding: false)
  end
end
