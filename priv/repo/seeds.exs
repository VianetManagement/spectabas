# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Spectabas.Repo
alias Spectabas.Accounts.Account
alias Spectabas.Accounts.User
alias Spectabas.Sites.Site

# Create demo account (tenant boundary). Per CLAUDE.md multi-tenancy section:
# superadmin role is account-scoped, sites belong to accounts via account_id.
demo_account =
  Repo.get_by(Account, slug: "demo") ||
    %Account{}
    |> Account.changeset(%{name: "Demo Account", slug: "demo"})
    |> Repo.insert!()
    |> tap(fn _ -> IO.puts("Created demo account") end)

# Create superadmin user if not exists, scoped to the demo account.
case Repo.get_by(User, email: "admin@spectabas.com") do
  nil ->
    %User{}
    |> User.email_changeset(%{email: "admin@spectabas.com"})
    |> User.password_changeset(%{password: "Admin123!@#456"})
    |> Ecto.Changeset.put_change(:role, :superadmin)
    |> Ecto.Changeset.put_change(:account_id, demo_account.id)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert!()

    IO.puts("Created superadmin user: admin@spectabas.com")

  %User{account_id: nil} = existing ->
    existing
    |> Ecto.Changeset.change(account_id: demo_account.id)
    |> Repo.update!()

    IO.puts("Backfilled account_id on admin@spectabas.com")

  _ ->
    :ok
end

# Create a demo site if not exists, attached to the demo account.
if !Repo.get_by(Site, domain: "demo.spectabas.com") do
  %Site{}
  |> Site.changeset(%{
    account_id: demo_account.id,
    name: "Demo Site",
    domain: "demo.spectabas.com",
    timezone: "UTC",
    gdpr_mode: "on"
  })
  |> Ecto.Changeset.put_change(:public_key, Site.generate_public_key())
  |> Repo.insert!()

  IO.puts("Created demo site: demo.spectabas.com")
end
