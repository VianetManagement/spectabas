import Config

config :spectabas,
  ecto_repos: [Spectabas.Repo],
  generators: [timestamp_type: :utc_datetime]

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :spectabas, SpectabasWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SpectabasWeb.ErrorHTML, json: SpectabasWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Spectabas.PubSub,
  live_view: [signing_salt: "spectabas_lv"],
  session_options: [
    store: :cookie,
    key: "_spectabas_session",
    signing_salt: "spectabas_session",
    same_site: "Lax",
    secure: true,
    http_only: true,
    domain: "www.spectabas.com"
  ]

config :spectabas, Spectabas.ClickHouse,
  url: "http://localhost:8123",
  database: "spectabas",
  username: "spectabas_writer",
  password: "",
  read_username: "spectabas_reader",
  read_password: ""

config :spectabas, Spectabas.Events.IngestBuffer,
  flush_interval_ms: 500,
  max_batch_size: 200

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 4, cleanup_interval_ms: 60_000 * 10]}

config :spectabas, :rate_limits,
  collect: {300, 60_000},
  login: {10, 60_000},
  password_reset: {5, 60_000},
  invite: {5, 60_000},
  totp: {5, 60_000},
  api: {1000, 60_000}

config :spectabas, Oban,
  repo: Spectabas.Repo,
  queues: [default: 10, mailer: 5, reports: 3, exports: 2, maintenance: 2],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       # 1st and 15th of each month at 06:00 UTC — refresh GeoIP databases
       {"0 6 1,15 * *", Spectabas.Workers.GeoIPRefresh},
       # Every 5 minutes — retry dead-lettered events when ClickHouse recovers
       {"*/5 * * * *", Spectabas.Workers.DeadLetterRetry},
       # Every 5 minutes — close stale sessions (idle > 30 minutes)
       {"*/5 * * * *", Spectabas.Workers.SessionCleanup},
       # Every 10 minutes — alert if dead letter queue is growing
       {"*/10 * * * *", Spectabas.Workers.DeadLetterMonitor},
       # Every 15 minutes — check for email reports due for sending
       {"*/15 * * * *", Spectabas.Workers.EmailReportDispatcher},
       # Daily at 7am UTC — detect potential spam referrer domains
       {"0 7 * * *", Spectabas.Workers.SpamDetector}
     ]}
  ]

config :spectabas, Spectabas.Mailer, adapter: Swoosh.Adapters.Local

config :spectabas, :invitation_ttl_hours, 48
config :spectabas, :api_key_prefix, "sab_live_"
config :spectabas, :visitor_cookie_name, "_sab"
config :spectabas, :visitor_cookie_max_age, 63_072_000
config :spectabas, :xdomain_token_ttl_seconds, 30
config :spectabas, :totp_required_roles, [:superadmin]

config :esbuild,
  version: "0.25.4",
  spectabas: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.12",
  spectabas: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :site_id, :user_id]

config :wax_,
  origin: "https://www.spectabas.com",
  rp_id: "spectabas.com"

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
