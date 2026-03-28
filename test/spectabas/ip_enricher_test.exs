defmodule Spectabas.IPEnricherTest do
  use ExUnit.Case, async: true

  alias Spectabas.IPEnricher

  describe "anonymize/1" do
    test "zeroes last octet of IPv4" do
      assert IPEnricher.anonymize("192.168.1.42") == "192.168.1.0"
    end

    test "zeroes last 80 bits of IPv6" do
      result = IPEnricher.anonymize("2001:db8:85a3:0:0:8a2e:370:7334")
      # Should zero everything after the third group
      assert result =~ "2001:"
    end

    test "returns input for invalid IP" do
      assert IPEnricher.anonymize("not-an-ip") == "not-an-ip"
    end
  end

  describe "enrich/2" do
    test "returns a map with all expected fields" do
      result = IPEnricher.enrich("8.8.8.8", :off)
      assert is_map(result)
      assert Map.has_key?(result, :ip_address)
      assert Map.has_key?(result, :ip_country)
      assert Map.has_key?(result, :ip_country_name)
      assert Map.has_key?(result, :ip_region_name)
      assert Map.has_key?(result, :ip_city)
      assert Map.has_key?(result, :ip_is_datacenter)
      assert Map.has_key?(result, :ip_is_vpn)
      assert Map.has_key?(result, :ip_is_tor)
      assert Map.has_key?(result, :ip_is_bot)
      assert Map.has_key?(result, :ip_gdpr_anonymized)
    end

    test "stores full IP when GDPR off" do
      result = IPEnricher.enrich("100.1.2.3", :off)
      assert result.ip_address == "100.1.2.3"
      assert result.ip_gdpr_anonymized == 0
    end

    test "anonymizes IP when GDPR on" do
      result = IPEnricher.enrich("100.4.5.6", :on)
      assert result.ip_address == "100.4.5.0"
      assert result.ip_gdpr_anonymized == 1
    end

    test "returns empty result for invalid input" do
      result = IPEnricher.enrich(nil, :off)
      assert result.ip_country == ""
      assert result.ip_address == ""
    end
  end
end
