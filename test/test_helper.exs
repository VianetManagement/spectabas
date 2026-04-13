ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Spectabas.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Spectabas.ObanRepo, :manual)
