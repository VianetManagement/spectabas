defmodule Spectabas.Events.CollectPayloadTest do
  use ExUnit.Case, async: true

  alias Spectabas.Events.CollectPayload

  describe "validate/1" do
    test "accepts valid pageview payload" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com/page",
        "r" => "https://google.com",
        "sw" => 1920,
        "sh" => 1080,
        "d" => 0,
        "p" => %{}
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload.t == "pageview"
      assert payload.u == "https://example.com/page"
    end

    test "accepts valid custom event" do
      params = %{
        "t" => "custom",
        "n" => "signup",
        "u" => "https://example.com",
        "p" => %{"plan" => "pro"}
      }

      assert {:ok, %CollectPayload{}} = CollectPayload.validate(params)
    end

    test "rejects invalid event type" do
      params = %{"t" => "invalid_type", "u" => "https://example.com"}
      assert {:error, _} = CollectPayload.validate(params)
    end

    test "rejects oversized URL" do
      params = %{"t" => "pageview", "u" => String.duplicate("x", 2049)}
      assert {:error, _} = CollectPayload.validate(params)
    end

    test "rejects too many custom properties" do
      props = for i <- 1..21, into: %{}, do: {"key#{i}", "val"}
      params = %{"t" => "pageview", "u" => "https://example.com", "p" => props}
      assert {:error, _} = CollectPayload.validate(params)
    end

    test "accepts bot detection fields" do
      params = %{"t" => "pageview", "u" => "https://example.com", "_bot" => 1, "_hi" => 0}
      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload._bot == 1
      assert payload._hi == 0
    end

    test "rejects non-map input" do
      assert {:error, :invalid_payload} = CollectPayload.validate("not a map")
    end
  end
end
