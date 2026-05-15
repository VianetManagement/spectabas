defmodule Spectabas.LogsTest do
  use ExUnit.Case, async: true

  alias Spectabas.Logs

  describe "parse_and_normalize/2" do
    test "parses a Render-style entry" do
      entry = %{
        "level" => "error",
        "message" => "** (RuntimeError) something broke",
        "timestamp" => "2026-05-15T10:00:00.000Z",
        "host" => "srv-abc123",
        "servicePrefix" => "spectabas-web"
      }

      row = Logs.parse_and_normalize(entry, 7)
      assert row.site_id == 7
      assert row.level == "error"
      assert row.host == "srv-abc123"
      assert row.source == "spectabas-web"
      assert row.message =~ "RuntimeError"
      assert row.error_fingerprint != ""
    end

    test "falls back to parsing level from message prefix" do
      entry = %{"message" => "[error] cannot connect", "timestamp" => "2026-05-15T10:00:00Z"}
      row = Logs.parse_and_normalize(entry, 7)
      assert row.level == "error"
    end

    test "info-level messages don't get fingerprinted" do
      entry = %{"level" => "info", "message" => "GET /api/sites/123/stats 200"}
      row = Logs.parse_and_normalize(entry, 7)
      assert row.level == "info"
      assert row.error_fingerprint == ""
    end

    test "normalizes message for fingerprinting (UUIDs, IDs, timestamps stripped)" do
      msg1 =
        "** (Ecto.NoResultsError) expected at least one result, got none for site 12345 at 2026-05-15T10:00:00Z"

      msg2 =
        "** (Ecto.NoResultsError) expected at least one result, got none for site 67890 at 2026-05-15T11:30:00Z"

      {fp1, _, _} = Logs.fingerprint_elixir_error(msg1, "error")
      {fp2, _, _} = Logs.fingerprint_elixir_error(msg2, "error")

      assert fp1 == fp2, "same error template should produce same fingerprint"
      assert fp1 != ""
    end

    test "extracts request_id from message when not in body" do
      entry = %{
        "level" => "error",
        "message" => "request_id=ABC123XYZ [error] something failed",
        "timestamp" => "2026-05-15T10:00:00Z"
      }

      row = Logs.parse_and_normalize(entry, 7)
      assert row.request_id == "ABC123XYZ"
    end

    test "handles unknown shapes by stringifying the body" do
      entry = %{"weird" => "shape", "no_message_field" => true}
      row = Logs.parse_and_normalize(entry, 7)
      assert row.site_id == 7
      # body got JSON-encoded into the message field
      assert row.message =~ "weird"
    end

    test "rejects non-map input" do
      assert Logs.parse_and_normalize("just a string", 7) == nil
      assert Logs.parse_and_normalize(nil, 7) == nil
    end

    test "truncates oversized fields" do
      huge_msg = String.duplicate("a", 20_000)
      entry = %{"level" => "info", "message" => huge_msg}
      row = Logs.parse_and_normalize(entry, 7)
      assert byte_size(row.message) == 8_000
    end
  end

  describe "fingerprint_elixir_error/2" do
    test "extracts module + line from Elixir-style stack trace" do
      msg = """
      ** (RuntimeError) oh no
          (spectabas 6.10.53) lib/spectabas/foo.ex:42: Spectabas.Foo.bar/1
      """

      {fp, module, line} = Logs.fingerprint_elixir_error(msg, "error")
      assert fp != ""
      assert module =~ "spectabas"
      assert line == 42
    end

    test "returns empty fingerprint for non-error levels without ** (Error) marker" do
      {fp, _, _} = Logs.fingerprint_elixir_error("GET /api 200", "info")
      assert fp == ""
    end

    test "still fingerprints info-level messages that look like Elixir errors" do
      msg = "** (ArgumentError) bad arg"
      {fp, _, _} = Logs.fingerprint_elixir_error(msg, "info")
      assert fp != ""
    end
  end

  describe "generate_token/0" do
    test "produces a 32-char base32 token" do
      tok = Logs.generate_token()
      assert is_binary(tok)
      assert String.length(tok) == 32
      assert tok =~ ~r/^[a-z2-7]+$/
    end

    test "is cryptographically random (no collisions in 100 generations)" do
      tokens = for _ <- 1..100, do: Logs.generate_token()
      assert length(Enum.uniq(tokens)) == 100
    end
  end
end
