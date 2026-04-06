defmodule Spectabas.ObanRepo do
  @moduledoc """
  Dedicated Ecto Repo for Oban background jobs.

  Uses the same database as Spectabas.Repo but with its own connection pool.
  This isolates background job processing from web request handling —
  a long-running sync job won't starve web requests of DB connections.

  Pool sizes:
  - ObanRepo: 25 connections (handles all Oban workers)
  - Repo: 10 connections (handles web requests only)
  """

  use Ecto.Repo,
    otp_app: :spectabas,
    adapter: Ecto.Adapters.Postgres
end
