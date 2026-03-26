defmodule Spectabas.Repo do
  use Ecto.Repo,
    otp_app: :spectabas,
    adapter: Ecto.Adapters.Postgres
end
