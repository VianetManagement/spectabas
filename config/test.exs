import Config

config :bcrypt_elixir, :log_rounds, 1

config :spectabas, Spectabas.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "spectabas_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :spectabas, SpectabasWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "9w/31jhW5mfSIJ/dg2GvRD3cepzmNhf7AUxWvJpy8bFHWssLrR83C6hHiAx/wSAU",
  server: false

config :spectabas, Spectabas.ClickHouse,
  url: System.get_env("CLICKHOUSE_URL", "http://localhost:8123"),
  database: System.get_env("CLICKHOUSE_DB", "spectabas_test"),
  username: System.get_env("CLICKHOUSE_WRITER_USER", "default"),
  password: System.get_env("CLICKHOUSE_WRITER_PASSWORD", ""),
  read_username: System.get_env("CLICKHOUSE_READER_USER", "default"),
  read_password: System.get_env("CLICKHOUSE_READER_PASSWORD", "")

config :spectabas, Oban, testing: :inline
config :spectabas, Spectabas.Mailer, adapter: Swoosh.Adapters.Test

config :swoosh, :api_client, false

config :wax_,
  origin: "https://localhost",
  rp_id: "localhost"

# Higher rate limits for tests to avoid cross-test interference
config :spectabas, :rate_limits,
  collect: {300, 60_000},
  login: {100, 60_000},
  password_reset: {50, 60_000},
  invite: {50, 60_000}

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
