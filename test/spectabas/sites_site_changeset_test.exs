defmodule Spectabas.Sites.SiteChangesetTest do
  use ExUnit.Case, async: true

  alias Spectabas.Sites.Site
  alias Spectabas.AdIntegrations.Vault

  describe "render_api_key encryption" do
    test "encrypts a submitted render_api_key into render_api_key_encrypted" do
      changeset =
        Site.changeset(%Site{name: "x", domain: "x.example.com"}, %{
          "name" => "x",
          "domain" => "x.example.com",
          "render_api_key" => "rnd_secret_value"
        })

      assert changeset.valid?
      encrypted = Ecto.Changeset.get_change(changeset, :render_api_key_encrypted)
      assert is_binary(encrypted)
      assert encrypted != "rnd_secret_value"
      assert Vault.decrypt(encrypted) == "rnd_secret_value"
    end

    test "leaves render_api_key_encrypted untouched if no render_api_key submitted" do
      existing_encrypted = Vault.encrypt("prior_key")

      changeset =
        Site.changeset(
          %Site{
            name: "x",
            domain: "x.example.com",
            render_api_key_encrypted: existing_encrypted
          },
          %{"name" => "x", "domain" => "x.example.com"}
        )

      assert changeset.valid?
      # No change to encrypted field
      assert Ecto.Changeset.get_change(changeset, :render_api_key_encrypted) == nil
    end

    test "ignores empty-string render_api_key (user cleared the input)" do
      changeset =
        Site.changeset(%Site{name: "x", domain: "x.example.com"}, %{
          "name" => "x",
          "domain" => "x.example.com",
          "render_api_key" => ""
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :render_api_key_encrypted) == nil
    end
  end

  describe "render_owner_id validation" do
    test "accepts tea- prefix" do
      changeset =
        Site.changeset(%Site{name: "x", domain: "x.example.com"}, %{
          "name" => "x",
          "domain" => "x.example.com",
          "render_owner_id" => "tea-abc123"
        })

      assert changeset.valid?
    end

    test "accepts usr- prefix" do
      changeset =
        Site.changeset(%Site{name: "x", domain: "x.example.com"}, %{
          "name" => "x",
          "domain" => "x.example.com",
          "render_owner_id" => "usr-abc123"
        })

      assert changeset.valid?
    end

    test "accepts empty string (clearing the field)" do
      changeset =
        Site.changeset(%Site{name: "x", domain: "x.example.com"}, %{
          "name" => "x",
          "domain" => "x.example.com",
          "render_owner_id" => ""
        })

      assert changeset.valid?
    end

    test "rejects other prefixes" do
      changeset =
        Site.changeset(%Site{name: "x", domain: "x.example.com"}, %{
          "name" => "x",
          "domain" => "x.example.com",
          "render_owner_id" => "srv-abc123"
        })

      refute changeset.valid?
      assert {:render_owner_id, _} = List.first(changeset.errors)
    end
  end
end
