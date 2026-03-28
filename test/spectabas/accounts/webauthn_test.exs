defmodule Spectabas.Accounts.WebauthnTest do
  use Spectabas.DataCase, async: true

  import Spectabas.AccountsFixtures

  alias Spectabas.Accounts.Webauthn

  describe "registration_challenge/1" do
    test "generates a challenge with correct structure" do
      user = user_fixture()
      {challenge, options} = Webauthn.registration_challenge(user)

      assert challenge != nil
      assert is_map(options)
      assert Map.has_key?(options, :challenge)
      assert Map.has_key?(options, :rp)
      assert Map.has_key?(options, :user)
      assert Map.has_key?(options, :pubKeyCredParams)
      assert options.user.name == user.email
    end
  end

  describe "list_credentials/1" do
    test "returns empty list for user with no credentials" do
      user = user_fixture()
      assert Webauthn.list_credentials(user) == []
    end
  end

  describe "has_credentials?/1" do
    test "returns false for user with no credentials" do
      user = user_fixture()
      refute Webauthn.has_credentials?(user)
    end
  end

  describe "authentication_challenge/1" do
    test "returns error when user has no credentials" do
      user = user_fixture()
      assert {:error, :no_credentials} = Webauthn.authentication_challenge(user)
    end
  end

  describe "delete_credential/1" do
    test "returns error for non-existent credential" do
      assert {:error, :not_found} = Webauthn.delete_credential(999_999)
    end
  end
end
