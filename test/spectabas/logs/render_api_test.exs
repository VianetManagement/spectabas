defmodule Spectabas.Logs.RenderAPITest do
  use ExUnit.Case, async: true

  alias Spectabas.Logs.RenderAPI

  describe "label/2" do
    test "returns the value of a named label from Render's logs response shape" do
      log = %{
        "labels" => [
          %{"name" => "type", "value" => "app"},
          %{"name" => "host", "value" => "srv-abc-host"}
        ],
        "message" => "..."
      }

      assert RenderAPI.label(log, "type") == "app"
      assert RenderAPI.label(log, "host") == "srv-abc-host"
    end

    test "returns empty string when the label is missing" do
      log = %{"labels" => [%{"name" => "type", "value" => "app"}], "message" => "..."}
      assert RenderAPI.label(log, "missing") == ""
    end

    test "returns empty string when labels is not a list" do
      assert RenderAPI.label(%{"labels" => nil}, "type") == ""
      assert RenderAPI.label(%{}, "type") == ""
    end

    test "returns empty string when input is not a map" do
      assert RenderAPI.label(nil, "type") == ""
      assert RenderAPI.label("not a map", "type") == ""
    end
  end
end
