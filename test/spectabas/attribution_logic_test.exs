defmodule Spectabas.AttributionLogicTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests the attribution logic to verify self-referrals don't
  corrupt first-touch and last-touch attribution.

  These tests verify the LOGIC, not the SQL execution (no ClickHouse in test).
  The key rule: internal navigations (no external referrer, no UTM, no click ID)
  should NOT be counted as attribution touchpoints.
  """

  describe "attribution signal detection" do
    # Simulates the has_signal filter logic from the SQL queries
    defp has_signal?(event) do
      (event.referrer_domain != "" and not self_referral?(event.referrer_domain)) or
        event.utm_source != "" or
        event.utm_medium != "" or
        event.utm_campaign != "" or
        event.click_id != ""
    end

    defp self_referral?(domain) do
      domain in ["www.roommates.com", "roommates.com", "b.roommates.com"]
    end

    test "external referrer has signal" do
      event = %{referrer_domain: "google.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: ""}
      assert has_signal?(event)
    end

    test "utm_source has signal" do
      event = %{referrer_domain: "", utm_source: "google", utm_medium: "", utm_campaign: "", click_id: ""}
      assert has_signal?(event)
    end

    test "click_id has signal" do
      event = %{referrer_domain: "", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "gclid_abc"}
      assert has_signal?(event)
    end

    test "self-referral without UTM has NO signal" do
      event = %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: ""}
      refute has_signal?(event)
    end

    test "empty referrer without UTM has NO signal (internal navigation)" do
      event = %{referrer_domain: "", utm_source: "", utm_medium: "", utm_campaign: "", click_id: ""}
      refute has_signal?(event)
    end

    test "self-referral WITH UTM still has signal (UTM overrides)" do
      event = %{referrer_domain: "www.roommates.com", utm_source: "newsletter", utm_medium: "", utm_campaign: "", click_id: ""}
      assert has_signal?(event)
    end

    test "self-referral WITH click_id still has signal" do
      event = %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "gclid_123"}
      assert has_signal?(event)
    end
  end

  describe "first-touch attribution with internal navigation" do
    # Simulates argMinIf(source, timestamp, has_signal)
    defp first_touch(events) do
      events
      |> Enum.filter(&has_signal?/1)
      |> Enum.sort_by(& &1.timestamp)
      |> case do
        [first | _] -> source_for(first)
        [] -> "Direct"
      end
    end

    defp last_touch(events) do
      events
      |> Enum.filter(&has_signal?/1)
      |> Enum.sort_by(& &1.timestamp, :desc)
      |> case do
        [last | _] -> source_for(last)
        [] -> "Direct"
      end
    end

    defp has_signal?(event) do
      (event.referrer_domain != "" and event.referrer_domain not in ["www.roommates.com", "roommates.com"]) or
        event.utm_source != "" or
        event.utm_medium != "" or
        event.utm_campaign != "" or
        event.click_id != ""
    end

    defp source_for(event) do
      cond do
        event.referrer_domain != "" and event.referrer_domain not in ["www.roommates.com", "roommates.com"] ->
          event.referrer_domain
        event.utm_source != "" ->
          event.utm_source
        true ->
          "Direct"
      end
    end

    test "first-touch credits external source, ignores self-referrals" do
      events = [
        %{referrer_domain: "google.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 1},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 2},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 3}
      ]

      assert first_touch(events) == "google.com"
    end

    test "last-touch credits external source, ignores trailing self-referrals" do
      events = [
        %{referrer_domain: "google.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 1},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 2},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 3}
      ]

      # Without the fix, this would be "Direct" (from self-referral at T3)
      # With the fix, it correctly returns "google.com" (only event with signal)
      assert last_touch(events) == "google.com"
    end

    test "last-touch credits most recent external source" do
      events = [
        %{referrer_domain: "google.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 1},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 2},
        %{referrer_domain: "facebook.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 4}
      ]

      assert last_touch(events) == "facebook.com"
    end

    test "click ID counts as signal for attribution" do
      events = [
        %{referrer_domain: "", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "gclid_abc", timestamp: 1},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 2}
      ]

      # The click ID event at T1 is the only one with signal
      assert first_touch(events) == "Direct"  # no referrer/utm, but has click_id
      assert last_touch(events) == "Direct"   # same — source_for doesn't use click_id for source label
    end

    test "pure direct visitor (no external referrer ever) returns Direct" do
      events = [
        %{referrer_domain: "", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 1},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 2}
      ]

      assert first_touch(events) == "Direct"
      assert last_touch(events) == "Direct"
    end

    test "UTM source from self-referral domain is still attributed" do
      events = [
        %{referrer_domain: "www.roommates.com", utm_source: "newsletter", utm_medium: "email", utm_campaign: "", click_id: "", timestamp: 1},
        %{referrer_domain: "www.roommates.com", utm_source: "", utm_medium: "", utm_campaign: "", click_id: "", timestamp: 2}
      ]

      assert first_touch(events) == "newsletter"
      assert last_touch(events) == "newsletter"
    end
  end
end
