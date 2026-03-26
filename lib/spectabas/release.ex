defmodule Spectabas.Release do
  @app :spectabas

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def create_admin(email, password) do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          alias Spectabas.Accounts.User

          case repo.get_by(User, email: email) do
            nil ->
              %User{}
              |> User.email_changeset(%{email: email})
              |> User.password_changeset(%{password: password})
              |> Ecto.Changeset.put_change(:role, :superadmin)
              |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
              |> repo.insert!()

              IO.puts("Created superadmin: #{email}")

            _user ->
              IO.puts("User #{email} already exists")
          end
        end)
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
