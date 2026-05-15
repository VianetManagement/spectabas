defmodule Spectabas.Logs.SyslogParser do
  @moduledoc """
  RFC 5424 syslog message parser, tuned for Render Log Streams + similar
  providers (Better Stack, Highlight, Papertrail) that send TLS syslog
  from Render.

  Render gives users two fields in the Log Stream UI: a `HOST:PORT`
  endpoint and an opaque `Token`. The Token is what tells us which
  Spectabas site the log line belongs to. Where exactly Render puts
  the token in the wire-format isn't documented and may vary, so this
  parser checks multiple plausible locations in order:

    1. RFC 5424 STRUCTURED-DATA: any SD-ELEMENT with a `token="..."`
       PARAM-VALUE (e.g. `[spectabas@xxx token="abc"]`)
    2. Leading bracketed token at the start of MSG: `[abc] real log...`
    3. Leading bare token at the start of MSG: `abc real log...`
       (Better Stack source-token convention)

  If none of those produce a token we know about, the message is
  rejected — we can't route it.

  ## Wire-frame parsing (RFC 5425)

  TLS-transported syslog uses octet-counted framing:

      MSG_LEN<SP>SYSLOG_MSG

  Where MSG_LEN is the byte count of SYSLOG_MSG as ASCII digits. This
  module exposes `decode_frames/1` that pulls as many complete frames
  as possible out of a binary buffer and returns the unconsumed tail
  for the next read. As a fallback, a buffer starting with `<` (no
  digit framing) is treated as newline-delimited non-transparent
  framing, used by some clients in violation of RFC 5425.
  """

  @doc """
  Parse a single RFC 5424 syslog message into a map.

  Returns `{:ok, map}` or `{:error, reason}`. The map keys match the
  shape produced by `Spectabas.Logs.parse_and_normalize/2` so the
  listener can feed it straight to the ingest buffer.

  ## Examples

      iex> msg = ~s(<134>1 2026-05-15T10:00:00Z host srv-abc - - [spectabas@1 token="tok123"] hello)
      iex> {:ok, parsed} = Spectabas.Logs.SyslogParser.parse(msg)
      iex> parsed.token
      "tok123"
      iex> parsed.message
      "hello"
  """
  def parse(bin) when is_binary(bin) do
    with {:ok, pri, rest} <- parse_pri(bin),
         {:ok, _version, rest} <- parse_version(rest),
         {:ok, ts, rest} <- parse_field(rest),
         {:ok, hostname, rest} <- parse_field(rest),
         {:ok, app_name, rest} <- parse_field(rest),
         {:ok, _procid, rest} <- parse_field(rest),
         {:ok, _msgid, rest} <- parse_field(rest),
         {:ok, sd, rest} <- parse_structured_data(rest) do
      msg = strip_leading_space(rest) |> strip_bom()
      {token, msg_after_token} = extract_token(sd, msg)

      {:ok,
       %{
         level: severity_to_level(pri_to_severity(pri)),
         timestamp: parse_timestamp(ts),
         hostname: hostname,
         app_name: app_name,
         token: token,
         message: msg_after_token,
         structured_data: sd
       }}
    end
  end

  def parse(_), do: {:error, :not_a_binary}

  @doc """
  Pull complete RFC 5425 octet-counted frames out of a buffer.

  Returns `{frames, remainder}` where `frames` is a list of complete
  syslog messages (without their length prefixes) and `remainder` is
  the unconsumed tail to keep for the next read.

  Falls back to newline framing if the buffer doesn't start with a
  digit + space — some clients send `\\n`-delimited messages on TLS
  even though that's against RFC 5425.
  """
  def decode_frames(buf) when is_binary(buf) do
    decode_frames(buf, [])
  end

  defp decode_frames(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp decode_frames(<<c, _::binary>> = buf, acc) when c in ?0..?9 do
    case parse_length_prefix(buf, "") do
      {:ok, len, after_prefix} when byte_size(after_prefix) >= len ->
        <<frame::binary-size(len), rest::binary>> = after_prefix
        decode_frames(rest, [frame | acc])

      {:ok, _len, _after_prefix} ->
        # Incomplete frame — keep entire buffer for next read.
        {Enum.reverse(acc), buf}

      :error ->
        # Malformed prefix — drop one byte and retry to resync.
        <<_, rest::binary>> = buf
        decode_frames(rest, acc)
    end
  end

  defp decode_frames(buf, acc) do
    case :binary.split(buf, "\n") do
      [frame, rest] ->
        trimmed = String.trim_trailing(frame, "\r")
        if trimmed == "", do: decode_frames(rest, acc), else: decode_frames(rest, [trimmed | acc])

      [_incomplete] ->
        {Enum.reverse(acc), buf}
    end
  end

  defp parse_length_prefix(<<c, rest::binary>>, digits) when c in ?0..?9,
    do: parse_length_prefix(rest, digits <> <<c>>)

  defp parse_length_prefix(<<?\s, rest::binary>>, digits) when digits != "",
    do: {:ok, String.to_integer(digits), rest}

  defp parse_length_prefix(_, _), do: :error

  # ---- PRI ----

  defp parse_pri(<<?<, rest::binary>>) do
    case :binary.split(rest, ">") do
      [digits, after_close] ->
        case Integer.parse(digits) do
          {n, ""} when n >= 0 and n <= 191 -> {:ok, n, after_close}
          _ -> {:error, :bad_pri}
        end

      _ ->
        {:error, :no_pri_close}
    end
  end

  defp parse_pri(_), do: {:error, :no_pri}

  defp pri_to_severity(pri), do: rem(pri, 8)

  defp severity_to_level(0), do: "critical"
  defp severity_to_level(1), do: "critical"
  defp severity_to_level(2), do: "critical"
  defp severity_to_level(3), do: "error"
  defp severity_to_level(4), do: "warning"
  defp severity_to_level(5), do: "notice"
  defp severity_to_level(6), do: "info"
  defp severity_to_level(7), do: "debug"
  defp severity_to_level(_), do: "info"

  # ---- Version ----

  defp parse_version(bin) do
    case parse_field(bin) do
      {:ok, v, rest} ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n, rest}
          _ -> {:error, :bad_version}
        end

      err ->
        err
    end
  end

  # ---- Space-delimited field (header parts) ----

  defp parse_field(bin) do
    case :binary.split(bin, " ") do
      [value, rest] -> {:ok, nil_dash(value), rest}
      [value] -> {:ok, nil_dash(value), ""}
    end
  end

  defp nil_dash("-"), do: ""
  defp nil_dash(other), do: other

  # ---- Structured data ----
  #
  # Format: `-` for none, or one or more `[SD-ID PARAM="value" ...]`
  # elements concatenated. We don't deeply parse — just return the raw
  # element list and let extract_token/2 grep for `token="..."`.

  defp parse_structured_data(<<?-, rest::binary>>) do
    {:ok, [], strip_leading_space(rest)}
  end

  defp parse_structured_data(<<?[, _::binary>> = bin) do
    parse_sd_elements(bin, [])
  end

  defp parse_structured_data(bin) do
    # No SD at all (some clients omit it entirely after the header).
    {:ok, [], bin}
  end

  defp parse_sd_elements(<<?[, rest::binary>>, acc) do
    case :binary.split(rest, "]") do
      [el, tail] -> parse_sd_elements(tail, [el | acc])
      _ -> {:error, :unterminated_sd}
    end
  end

  defp parse_sd_elements(bin, acc) do
    {:ok, Enum.reverse(acc), strip_leading_space(bin)}
  end

  defp strip_leading_space(<<?\s, rest::binary>>), do: rest
  defp strip_leading_space(other), do: other

  # Strip UTF-8 BOM that RFC 5424 allows at the start of MSG.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(other), do: other

  # ---- Token extraction ----

  defp extract_token(sd_elements, msg) do
    case token_from_sd(sd_elements) do
      nil -> token_from_msg(msg)
      tok -> {tok, msg}
    end
  end

  defp token_from_sd(sd_elements) do
    Enum.find_value(sd_elements, fn el ->
      case Regex.run(~r/\btoken="([^"]+)"/, el) do
        [_, t] -> t
        _ -> nil
      end
    end)
  end

  # Render's "Token" field in the Log Stream UI may end up in the
  # syslog MSG itself rather than in structured data. Two common
  # shapes — bracketed and bare — both at the start of the message.
  defp token_from_msg(msg) do
    cond do
      match = Regex.run(~r/^\[([A-Za-z0-9_\-=]{8,200})\]\s+(.*)$/s, msg) ->
        [_, tok, rest] = match
        {tok, rest}

      match = Regex.run(~r/^([A-Za-z0-9_\-=]{16,200})\s+(.*)$/s, msg) ->
        [_, tok, rest] = match
        {tok, rest}

      true ->
        {nil, msg}
    end
  end

  defp parse_timestamp(""), do: DateTime.utc_now()

  defp parse_timestamp(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
