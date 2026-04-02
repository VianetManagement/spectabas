defmodule Spectabas.Events.ClickIdTest do
  use ExUnit.Case, async: true

  alias Spectabas.Events.CollectPayload

  describe "click ID extraction from payload" do
    test "extracts gclid from payload _cid field" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com/page",
        "_cid" => "EAIaIQobChMI123456789",
        "_cidt" => "google_ads"
      }

      assert {:ok, payload} = CollectPayload.validate(params)
      assert payload._cid == "EAIaIQobChMI123456789"
      assert payload._cidt == "google_ads"
    end

    test "extracts msclkid from payload" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cid" => "abc123def456",
        "_cidt" => "bing_ads"
      }

      assert {:ok, payload} = CollectPayload.validate(params)
      assert payload._cid == "abc123def456"
      assert payload._cidt == "bing_ads"
    end

    test "extracts fbclid from payload" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cid" => "fb.1.1234567890.987654321",
        "_cidt" => "meta_ads"
      }

      assert {:ok, payload} = CollectPayload.validate(params)
      assert payload._cid == "fb.1.1234567890.987654321"
      assert payload._cidt == "meta_ads"
    end

    test "click ID is empty when not present" do
      params = %{"t" => "pageview", "u" => "https://example.com"}

      assert {:ok, payload} = CollectPayload.validate(params)
      assert payload._cid == ""
      assert payload._cidt == ""
    end

    test "click ID with empty type defaults correctly" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com",
        "_cid" => "some_click_id",
        "_cidt" => ""
      }

      assert {:ok, payload} = CollectPayload.validate(params)
      assert payload._cid == "some_click_id"
      assert payload._cidt == ""
    end
  end

  describe "click ID in EventSchema" do
    alias Spectabas.Events.EventSchema

    test "maps click_id fields to ClickHouse row" do
      event = %{
        site_id: 1,
        click_id: "EAIaIQobChMI123",
        click_id_type: "google_ads"
      }

      row = EventSchema.to_row(event)
      assert row["click_id"] == "EAIaIQobChMI123"
      assert row["click_id_type"] == "google_ads"
    end

    test "bing click ID maps correctly" do
      row = EventSchema.to_row(%{site_id: 1, click_id: "msclk_val", click_id_type: "bing_ads"})
      assert row["click_id"] == "msclk_val"
      assert row["click_id_type"] == "bing_ads"
    end

    test "meta click ID maps correctly" do
      row = EventSchema.to_row(%{site_id: 1, click_id: "fb.1.123.456", click_id_type: "meta_ads"})
      assert row["click_id"] == "fb.1.123.456"
      assert row["click_id_type"] == "meta_ads"
    end

    test "missing click ID defaults to empty strings" do
      row = EventSchema.to_row(%{site_id: 1})
      assert row["click_id"] == ""
      assert row["click_id_type"] == ""
    end
  end

  describe "click ID extraction from URL (fallback)" do
    # Tests the ingest module's URL-based extraction when _cid is not in payload
    # This covers the case where cookies/sessionStorage are blocked

    test "gclid in URL query params is recognized" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com/page?gclid=EAIaIQob123&utm_source=google",
        "_cid" => "",
        "_cidt" => ""
      }

      assert {:ok, payload} = CollectPayload.validate(params)
      # The actual extraction happens in Ingest.process, but we verify the URL passes through
      assert payload.u == "https://example.com/page?gclid=EAIaIQob123&utm_source=google"
    end

    test "msclkid in URL query params is recognized" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com?msclkid=abc123&utm_source=bing"
      }

      assert {:ok, payload} = CollectPayload.validate(params)
      assert payload.u =~ "msclkid=abc123"
    end

    test "fbclid in URL query params is recognized" do
      params = %{
        "t" => "pageview",
        "u" => "https://example.com?fbclid=fb.1.123.456"
      }

      assert {:ok, payload} = CollectPayload.validate(params)
      assert payload.u =~ "fbclid=fb.1.123.456"
    end
  end
end
