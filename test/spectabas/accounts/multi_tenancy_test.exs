defmodule Spectabas.Accounts.MultiTenancyTest do
  use Spectabas.DataCase, async: true

  alias Spectabas.{Accounts, Sites, Repo}
  alias Spectabas.Accounts.{Account, User, Invitation}
  import Spectabas.AccountsFixtures

  defp create_account(name, slug) do
    Repo.insert!(%Account{name: name, slug: slug, site_limit: 10, active: true})
  end

  defp create_user(email, role, account) do
    {:ok, user} = Accounts.register_user(%{email: email})

    {:ok, user} =
      user
      |> User.profile_changeset(%{role: role, account_id: account.id})
      |> Repo.update()

    user
  end

  defp create_platform_admin(email) do
    {:ok, user} = Accounts.register_user(%{email: email})

    {:ok, user} =
      user
      |> User.profile_changeset(%{role: :platform_admin, account_id: nil})
      |> Repo.update()

    user
  end

  defp create_site(name, domain, account) do
    {:ok, site} =
      Sites.create_site(%{"name" => name, "domain" => domain, "account_id" => account.id})

    site
  end

  describe "account isolation" do
    test "superadmin can only see their own account's sites" do
      acct_a = create_account("Account A", "acct-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("Account B", "acct-b-#{System.unique_integer([:positive])}")

      admin_a = create_user("admin-a-#{System.unique_integer()}@test.com", :superadmin, acct_a)
      admin_b = create_user("admin-b-#{System.unique_integer()}@test.com", :superadmin, acct_b)

      site_a = create_site("Site A", "b.site-a-#{System.unique_integer([:positive])}.com", acct_a)
      site_b = create_site("Site B", "b.site-b-#{System.unique_integer([:positive])}.com", acct_b)

      # Admin A sees only Site A
      sites_a = Accounts.accessible_sites(admin_a)
      assert Enum.any?(sites_a, &(&1.id == site_a.id))
      refute Enum.any?(sites_a, &(&1.id == site_b.id))

      # Admin B sees only Site B
      sites_b = Accounts.accessible_sites(admin_b)
      assert Enum.any?(sites_b, &(&1.id == site_b.id))
      refute Enum.any?(sites_b, &(&1.id == site_a.id))
    end

    test "superadmin cannot access another account's site" do
      acct_a = create_account("Account A", "iso-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("Account B", "iso-b-#{System.unique_integer([:positive])}")

      admin_a =
        create_user("iso-admin-a-#{System.unique_integer()}@test.com", :superadmin, acct_a)

      site_b = create_site("Site B", "b.iso-b-#{System.unique_integer([:positive])}.com", acct_b)

      refute Accounts.can_access_site?(admin_a, site_b)
    end

    test "superadmin can only see their own account's users" do
      acct_a = create_account("Users A", "users-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("Users B", "users-b-#{System.unique_integer([:positive])}")

      admin_a =
        create_user("users-admin-a-#{System.unique_integer()}@test.com", :superadmin, acct_a)

      _user_a =
        create_user("users-analyst-a-#{System.unique_integer()}@test.com", :analyst, acct_a)

      _user_b =
        create_user("users-analyst-b-#{System.unique_integer()}@test.com", :analyst, acct_b)

      users = Accounts.list_users(admin_a)
      emails = Enum.map(users, & &1.email)
      assert Enum.any?(emails, &String.contains?(&1, "admin-a"))
      assert Enum.any?(emails, &String.contains?(&1, "analyst-a"))
      refute Enum.any?(emails, &String.contains?(&1, "analyst-b"))
    end
  end

  describe "platform admin" do
    test "platform admin sees all sites across all accounts" do
      acct_a = create_account("PA Sites A", "pa-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("PA Sites B", "pa-b-#{System.unique_integer([:positive])}")

      site_a =
        create_site("PA Site A", "b.pa-a-#{System.unique_integer([:positive])}.com", acct_a)

      site_b =
        create_site("PA Site B", "b.pa-b-#{System.unique_integer([:positive])}.com", acct_b)

      pa = create_platform_admin("pa-#{System.unique_integer()}@test.com")

      sites = Accounts.accessible_sites(pa)
      site_ids = Enum.map(sites, & &1.id)
      assert site_a.id in site_ids
      assert site_b.id in site_ids
    end

    test "platform admin can access any site" do
      acct = create_account("PA Access", "pa-acc-#{System.unique_integer([:positive])}")
      site = create_site("PA Site", "b.pa-acc-#{System.unique_integer([:positive])}.com", acct)
      pa = create_platform_admin("pa-acc-#{System.unique_integer()}@test.com")

      assert Accounts.can_access_site?(pa, site)
    end

    test "platform admin sees all users" do
      acct = create_account("PA Users", "pa-usr-#{System.unique_integer([:positive])}")
      _user = create_user("pa-usr-analyst-#{System.unique_integer()}@test.com", :analyst, acct)
      pa = create_platform_admin("pa-usr-#{System.unique_integer()}@test.com")

      users = Accounts.list_users(pa)
      assert length(users) >= 2
    end

    test "platform admin can create accounts" do
      pa = create_platform_admin("pa-create-#{System.unique_integer()}@test.com")

      {:ok, account} =
        Accounts.create_account(pa, %{
          "name" => "New Account",
          "slug" => "new-acct-#{System.unique_integer([:positive])}"
        })

      assert account.name == "New Account"
      assert account.site_limit == 10
    end
  end

  describe "site limits" do
    test "can_create_site? returns false when at limit" do
      acct = create_account("Limit Test", "limit-#{System.unique_integer([:positive])}")
      acct = Repo.update!(Account.changeset(acct, %{site_limit: 1}))

      admin = create_user("limit-admin-#{System.unique_integer()}@test.com", :superadmin, acct)

      # Create one site (at limit)
      create_site("Limit Site", "b.limit-#{System.unique_integer([:positive])}.com", acct)

      refute Accounts.can_create_site?(admin)
    end

    test "can_create_site? returns true when under limit" do
      acct = create_account("Under Limit", "under-#{System.unique_integer([:positive])}")
      admin = create_user("under-admin-#{System.unique_integer()}@test.com", :superadmin, acct)

      assert Accounts.can_create_site?(admin)
    end

    test "platform admin always passes site limit check" do
      pa = create_platform_admin("pa-limit-#{System.unique_integer()}@test.com")
      assert Accounts.can_create_site?(pa)
    end
  end

  describe "cross-account security" do
    test "superadmin cannot access site from another account" do
      acct_a = create_account("Sec A", "sec-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("Sec B", "sec-b-#{System.unique_integer([:positive])}")

      admin_a = create_user("sec-a-#{System.unique_integer()}@test.com", :superadmin, acct_a)

      site_b =
        create_site("Sec Site B", "b.sec-b-#{System.unique_integer([:positive])}.com", acct_b)

      refute Accounts.can_access_site?(admin_a, site_b)
    end

    test "admin cannot access site from another account" do
      acct_a = create_account("Adm A", "adm-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("Adm B", "adm-b-#{System.unique_integer([:positive])}")

      admin_a = create_user("adm-a-#{System.unique_integer()}@test.com", :admin, acct_a)

      site_b =
        create_site("Adm Site B", "b.adm-b-#{System.unique_integer([:positive])}.com", acct_b)

      refute Accounts.can_access_site?(admin_a, site_b)
    end

    test "analyst with permission cannot access site from another account" do
      acct_a = create_account("Ana A", "ana-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("Ana B", "ana-b-#{System.unique_integer([:positive])}")

      analyst = create_user("ana-#{System.unique_integer()}@test.com", :analyst, acct_a)

      site_b =
        create_site("Ana Site B", "b.ana-b-#{System.unique_integer([:positive])}.com", acct_b)

      # Even if they somehow got a permission record, account check blocks access
      refute Accounts.can_access_site?(analyst, site_b)
    end

    test "platform_admin can access site from any account" do
      acct = create_account("PA Cross", "pa-cross-#{System.unique_integer([:positive])}")

      site =
        create_site("PA Cross Site", "b.pa-cross-#{System.unique_integer([:positive])}.com", acct)

      pa = create_platform_admin("pa-cross-#{System.unique_integer()}@test.com")

      assert Accounts.can_access_site?(pa, site)
    end

    test "superadmin can access own account's site" do
      acct = create_account("Own A", "own-a-#{System.unique_integer([:positive])}")
      admin = create_user("own-a-#{System.unique_integer()}@test.com", :superadmin, acct)
      site = create_site("Own Site", "b.own-a-#{System.unique_integer([:positive])}.com", acct)

      assert Accounts.can_access_site?(admin, site)
    end
  end

  describe "invitations with accounts" do
    test "invitation carries account_id to new user" do
      acct = create_account("Invite Acct", "inv-#{System.unique_integer([:positive])}")
      admin = create_user("inv-admin-#{System.unique_integer()}@test.com", :superadmin, acct)

      email = "inv-new-#{System.unique_integer()}@test.com"
      {:ok, invitation} = Accounts.invite_user(admin, email, :analyst, acct.id)

      assert invitation.account_id == acct.id

      # Accept the invitation
      {:ok, user} =
        Accounts.accept_invitation(invitation.token, %{
          email: email,
          password: "a_good_password123"
        })

      assert user.account_id == acct.id
      assert user.role == :analyst
    end

    test "list_pending_invitations scoped to account" do
      acct_a = create_account("Inv A", "inv-a-#{System.unique_integer([:positive])}")
      acct_b = create_account("Inv B", "inv-b-#{System.unique_integer([:positive])}")

      admin_a =
        create_user("inv-a-admin-#{System.unique_integer()}@test.com", :superadmin, acct_a)

      admin_b =
        create_user("inv-b-admin-#{System.unique_integer()}@test.com", :superadmin, acct_b)

      {:ok, _} =
        Accounts.invite_user(
          admin_a,
          "inv-a-user-#{System.unique_integer()}@test.com",
          :analyst,
          acct_a.id
        )

      {:ok, _} =
        Accounts.invite_user(
          admin_b,
          "inv-b-user-#{System.unique_integer()}@test.com",
          :analyst,
          acct_b.id
        )

      pending_a = Accounts.list_pending_invitations(admin_a)
      pending_b = Accounts.list_pending_invitations(admin_b)

      assert length(pending_a) >= 1
      assert length(pending_b) >= 1

      # Ensure no cross-account invitations leak
      acct_a_ids = Enum.map(pending_a, & &1.account_id) |> Enum.uniq()
      assert acct_a_ids == [acct_a.id]
    end
  end
end
