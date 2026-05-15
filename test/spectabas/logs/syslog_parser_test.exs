defmodule Spectabas.Logs.SyslogParserTest do
  use ExUnit.Case, async: true

  alias Spectabas.Logs.SyslogParser

  describe "parse/1" do
    test "parses an RFC 5424 message with token in structured data" do
      msg =
        ~s(<134>1 2026-05-15T10:00:00Z my-host srv-abc - - [spectabas@99 token="tok123"] hello world)

      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert parsed.token == "tok123"
      assert parsed.message == "hello world"
      assert parsed.hostname == "my-host"
      assert parsed.app_name == "srv-abc"
      # PRI 134 = facility 16 * 8 + severity 6 = info
      assert parsed.level == "info"
    end

    test "parses with dashes for nil-able header fields" do
      msg = ~s(<11>1 2026-05-15T10:00:00Z - - - - - [spectabas@1 token="abc"] something broke)
      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert parsed.hostname == ""
      assert parsed.app_name == ""
      # PRI 11 = error severity (3)
      assert parsed.level == "error"
    end

    test "extracts token from bracketed message prefix when no SD token" do
      msg = ~s(<134>1 2026-05-15T10:00:00Z host app - - - [tok_abc_123] real log line)
      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert parsed.token == "tok_abc_123"
      assert parsed.message == "real log line"
    end

    test "extracts token from bare-prefix message when long enough" do
      msg = ~s(<134>1 2026-05-15T10:00:00Z host app - - - aaaaaaaaaaaaaaaa actual message)
      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert parsed.token == "aaaaaaaaaaaaaaaa"
      assert parsed.message == "actual message"
    end

    test "returns nil token if no token can be located" do
      msg = ~s(<134>1 2026-05-15T10:00:00Z host app - - - just a regular message)
      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert parsed.token == nil
    end

    test "handles SD with multiple elements, finds token in any of them" do
      msg =
        ~s(<134>1 2026-05-15T10:00:00Z host app - - [origin@1 sw="ren"][auth@2 token="zzz"] msg)

      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert parsed.token == "zzz"
    end

    test "strips UTF-8 BOM that RFC 5424 allows at start of MSG" do
      msg =
        <<"<134>1 2026-05-15T10:00:00Z host app - - - "::binary, 0xEF, 0xBB, 0xBF,
          "after bom"::binary>>

      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert parsed.message == "after bom"
    end

    test "severity 0/1/2 → critical" do
      for {pri, expected} <- [{0, "critical"}, {9, "critical"}, {10, "critical"}] do
        msg = "<#{pri}>1 2026-05-15T10:00:00Z host app - - - msg"
        assert {:ok, parsed} = SyslogParser.parse(msg)
        assert parsed.level == expected, "PRI #{pri} → #{parsed.level}, expected #{expected}"
      end
    end

    test "rejects non-binary input" do
      assert {:error, _} = SyslogParser.parse(:not_a_binary)
      assert {:error, _} = SyslogParser.parse(nil)
    end

    test "rejects message without PRI" do
      assert {:error, _} = SyslogParser.parse("no PRI at all")
    end

    test "parses timestamp into DateTime" do
      msg = ~s(<134>1 2026-05-15T10:00:00.123Z host app - - - msg)
      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert %DateTime{} = parsed.timestamp
      assert parsed.timestamp.year == 2026
    end

    test "uses now() when timestamp is dash" do
      msg = ~s(<134>1 - host app - - - msg)
      assert {:ok, parsed} = SyslogParser.parse(msg)
      assert %DateTime{} = parsed.timestamp
      # Should be very recent
      assert DateTime.diff(DateTime.utc_now(), parsed.timestamp) < 5
    end
  end

  describe "decode_frames/1 — octet-counted (RFC 5425)" do
    test "decodes a single complete frame" do
      payload = "<134>1 2026-05-15T10:00:00Z h a - - - hi"
      buf = "#{byte_size(payload)} #{payload}"
      assert {[^payload], <<>>} = SyslogParser.decode_frames(buf)
    end

    test "decodes multiple back-to-back frames" do
      p1 = "<11>1 2026-05-15T10:00:00Z h a - - - one"
      p2 = "<11>1 2026-05-15T10:00:01Z h a - - - two"
      buf = "#{byte_size(p1)} #{p1}#{byte_size(p2)} #{p2}"
      assert {[^p1, ^p2], <<>>} = SyslogParser.decode_frames(buf)
    end

    test "returns remainder on partial frame" do
      payload = "<11>1 2026-05-15T10:00:00Z h a - - - hello"
      full = "#{byte_size(payload)} #{payload}"
      # Cut mid-payload
      partial = binary_part(full, 0, byte_size(full) - 5)
      assert {[], remainder} = SyslogParser.decode_frames(partial)
      assert remainder == partial
    end

    test "remainder continues correctly across reads" do
      p1 = "<11>1 2026-05-15T10:00:00Z h a - - - first"
      p2 = "<11>1 2026-05-15T10:00:00Z h a - - - second"
      full = "#{byte_size(p1)} #{p1}#{byte_size(p2)} #{p2}"

      # Read 1: first byte through middle of p2
      split = byte_size(p1) + byte_size("#{byte_size(p1)} ") + 10
      part1 = binary_part(full, 0, split)
      part2 = binary_part(full, split, byte_size(full) - split)

      {frames1, rem1} = SyslogParser.decode_frames(part1)
      assert frames1 == [p1]

      {frames2, rem2} = SyslogParser.decode_frames(rem1 <> part2)
      assert frames2 == [p2]
      assert rem2 == <<>>
    end
  end

  describe "decode_frames/1 — newline-delimited fallback" do
    test "splits on newline when buffer doesn't start with a digit" do
      p1 = "<11>1 2026-05-15T10:00:00Z h a - - - one"
      p2 = "<11>1 2026-05-15T10:00:01Z h a - - - two"
      buf = "#{p1}\n#{p2}\n"
      assert {[^p1, ^p2], <<>>} = SyslogParser.decode_frames(buf)
    end

    test "newline fallback keeps incomplete last line as remainder" do
      buf = "<11>1 ... full line\n<11>1 partial"
      {frames, rem} = SyslogParser.decode_frames(buf)
      assert frames == ["<11>1 ... full line"]
      assert rem == "<11>1 partial"
    end

    test "strips trailing CR in CRLF-delimited frames" do
      buf = "<11>1 line one\r\n<11>1 line two\r\n"
      {frames, _} = SyslogParser.decode_frames(buf)
      assert frames == ["<11>1 line one", "<11>1 line two"]
    end
  end
end
