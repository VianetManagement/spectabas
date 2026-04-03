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

    test "accepts click ID fields (gclid)" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cid" => "EAIaIQobChMI123456",
        "_cidt" => "google_ads"
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload._cid == "EAIaIQobChMI123456"
      assert payload._cidt == "google_ads"
    end

    test "accepts msclkid click ID" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cid" => "msclk_abc123",
        "_cidt" => "bing_ads"
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload._cid == "msclk_abc123"
      assert payload._cidt == "bing_ads"
    end

    test "accepts fbclid click ID" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cid" => "fb.1.123456.789",
        "_cidt" => "meta_ads"
      }

      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload._cid == "fb.1.123456.789"
      assert payload._cidt == "meta_ads"
    end

    test "click ID defaults to empty string" do
      params = %{"t" => "pageview", "u" => "https://example.com"}
      assert {:ok, %CollectPayload{} = payload} = CollectPayload.validate(params)
      assert payload._cid == ""
      assert payload._cidt == ""
    end

    test "rejects oversized fingerprint" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_fp" => String.duplicate("a", 257)
      }

      assert {:error, _} = CollectPayload.validate(params)
    end

    test "rejects oversized click ID" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cid" => String.duplicate("a", 257)
      }

      assert {:error, _} = CollectPayload.validate(params)
    end

    test "rejects oversized click ID type" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cidt" => String.duplicate("a", 33)
      }

      assert {:error, _} = CollectPayload.validate(params)
    end

    test "accepts fingerprint at max length" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_fp" => String.duplicate("a", 256)
      }

      assert {:ok, _} = CollectPayload.validate(params)
    end
  end
end
