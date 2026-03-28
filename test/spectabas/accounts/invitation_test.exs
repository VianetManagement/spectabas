defmodule Spectabas.Accounts.InvitationTest do
  use Spectabas.DataCase, async: true

  import Spectabas.AccountsFixtures

  alias Spectabas.Accounts

  describe "invite_user/3" do
    test "creates a pending invitation" do
      admin = user_fixture()
      {:ok, admin} = admin |> Accounts.User.profile_changeset(%{role: :superadmin}) |> Repo.update()

      assert {:ok, invitation} = Accounts.invite_user(admin, "new@example.com", "analyst")
      assert invitation.email == "new@example.com"
      assert invitation.role == :analyst
      assert invitation.token != nil
      assert invitation.token_hash != nil
      assert invitation.accepted_at == nil
    end

    test "rejects invalid email" do
      admin = user_fixture()
      {:ok, admin} = admin |> Accounts.User.profile_changeset(%{role: :superadmin}) |> Repo.update()

      assert {:error, _changeset} = Accounts.invite_user(admin, "not-an-email", "analyst")
    end
  end

  describe "get_valid_invitation/1" do
    test "finds invitation by token" do
      admin = user_fixture()
      {:ok, admin} = admin |> Accounts.User.profile_changeset(%{role: :superadmin}) |> Repo.update()
      {:ok, invitation} = Accounts.invite_user(admin, "find@example.com", "viewer")

      assert {:ok, found} = Accounts.get_valid_invitation(invitation.token)
      assert found.email == "find@example.com"
    end

    test "rejects invalid token" do
      assert {:error, :not_found} = Accounts.get_valid_invitation("bogus-token")
    end
  end

  describe "accept_invitation/2" do
    test "creates user and marks invitation as accepted" do
      admin = user_fixture()
      {:ok, admin} = admin |> Accounts.User.profile_changeset(%{role: :superadmin}) |> Repo.update()
      {:ok, invitation} = Accounts.invite_user(admin, "accept@example.com", "analyst")

      assert {:ok, user} =
               Accounts.accept_invitation(invitation.token, %{
                 email: "accept@example.com",
                 password: "a_good_password123"
               })

      assert user.email == "accept@example.com"
      assert user.role == :analyst
    end

    test "rejects already accepted invitation" do
      admin = user_fixture()
      {:ok, admin} = admin |> Accounts.User.profile_changeset(%{role: :superadmin}) |> Repo.update()
      {:ok, invitation} = Accounts.invite_user(admin, "once@example.com", "viewer")

      assert {:ok, _user} =
               Accounts.accept_invitation(invitation.token, %{
                 email: "once@example.com",
                 password: "a_good_password123"
               })

      # Second attempt should fail
      assert {:error, _} =
               Accounts.accept_invitation(invitation.token, %{
                 email: "once@example.com",
                 password: "a_good_password123"
               })
    end
  end

  describe "list_pending_invitations/0" do
    test "returns only unaccepted invitations" do
      admin = user_fixture()
      {:ok, admin} = admin |> Accounts.User.profile_changeset(%{role: :superadmin}) |> Repo.update()

      {:ok, _inv1} = Accounts.invite_user(admin, "pending1@example.com", "analyst")
      {:ok, inv2} = Accounts.invite_user(admin, "pending2@example.com", "viewer")

      # Accept one
      Accounts.accept_invitation(inv2.token, %{
        email: "pending2@example.com",
        password: "a_good_password123"
      })

      pending = Accounts.list_pending_invitations()
      emails = Enum.map(pending, & &1.email)
      assert "pending1@example.com" in emails
      refute "pending2@example.com" in emails
    end
  end
end
