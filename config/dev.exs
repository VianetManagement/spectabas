import Config

config :spectabas, Spectabas.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "spectabas_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :spectabas, SpectabasWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "VJNZ6Q2Rq+ybRudZCvcl7cxh/EPVEGDamgWUW345ZPCYXkqEPFwVVdMhVFaZon6+",
  session_options: [
    store: :cookie,
    key: "_spectabas_session",
    signing_salt: "spectabas_session",
    same_site: "Lax",
    secure: false,
    http_only: true
  ],
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:spectabas, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:spectabas, ~w(--watch)]}
  ]

config :spectabas, SpectabasWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*\.po$",
      ~r"lib/spectabas_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :spectabas, Spectabas.ClickHouse,
  url: "http://localhost:8123",
  database: "spectabas_dev",
  username: "default",
  password: "",
  read_username: "default",
  read_password: ""

config :spectabas, :dev_routes, true

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :swoosh, :api_client, false
