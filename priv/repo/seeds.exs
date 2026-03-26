# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs

alias Spectabas.Repo
alias Spectabas.Accounts.User
alias Spectabas.Sites.Site

# Create superadmin user if not exists
unless Repo.get_by(User, email: "admin@spectabas.com") do
  %User{}
  |> User.email_changeset(%{email: "admin@spectabas.com"})
  |> User.password_changeset(%{password: "Admin123!@#456"})
  |> Ecto.Changeset.put_change(:role, :superadmin)
  |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
  |> Repo.insert!()

  IO.puts("Created superadmin user: admin@spectabas.com")
end

# Create a demo site if not exists
unless Repo.get_by(Site, domain: "demo.spectabas.com") do
  %Site{}
  |> Site.changeset(%{
    name: "Demo Site",
    domain: "demo.spectabas.com",
    public_key: Site.generate_public_key(),
    timezone: "UTC",
    gdpr_mode: "on"
  })
  |> Repo.insert!()

  IO.puts("Created demo site: demo.spectabas.com")
end
