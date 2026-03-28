defmodule Spectabas.Events.IngestTest do
  use ExUnit.Case, async: true

  alias Spectabas.Events.Ingest

  describe "extract_client_ip/1" do
    test "extracts from CF-Connecting-IP header (Cloudflare)" do
      conn = %Plug.Conn{
        req_headers: [{"cf-connecting-ip", "1.2.3.4"}],
        remote_ip: {127, 0, 0, 1}
      }

      assert Ingest.extract_client_ip(conn) == "1.2.3.4"
    end

    test "extracts from x-forwarded-for header" do
      conn = %Plug.Conn{
        req_headers: [{"x-forwarded-for", "5.6.7.8, 10.0.0.1"}],
        remote_ip: {127, 0, 0, 1}
      }

      assert Ingest.extract_client_ip(conn) == "5.6.7.8"
    end

    test "prefers CF-Connecting-IP over x-forwarded-for" do
      conn = %Plug.Conn{
        req_headers: [
          {"cf-connecting-ip", "1.2.3.4"},
          {"x-forwarded-for", "5.6.7.8"}
        ],
        remote_ip: {127, 0, 0, 1}
      }

      assert Ingest.extract_client_ip(conn) == "1.2.3.4"
    end

    test "falls back to remote_ip" do
      conn = %Plug.Conn{
        req_headers: [],
        remote_ip: {192, 168, 1, 1}
      }

      assert Ingest.extract_client_ip(conn) == "192.168.1.1"
    end
  end
end
