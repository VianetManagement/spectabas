# Spectabas — master build prompt for Claude Code

You are building **Spectabas**, a multi-tenant web analytics SaaS platform
from scratch. This prompt is your complete specification. Execute every
phase in order. Do not stop between phases unless you hit an unresolvable
error — fix errors automatically where possible and continue.

---

## Standing rules — apply to every file you write

**Security (apply without being asked):**
- Validate and sanitize all external input with type checks, length limits, allowlists
- Use `ClickHouse.param/1` for every value interpolated into a ClickHouse query — no raw string concatenation
- Enforce authorization at the context layer, not just the router
- Never trust Oban job args — always re-fetch the resource from DB by ID
- Store all tokens hashed (SHA-256); plaintext only returned once, never persisted
- Session cookie scoped strictly to `www.spectabas.com` — never `.spectabas.com`
- All secrets via environment variables; raise at startup if missing in prod
- Audit log every privilege-sensitive action
- Rate limit all unauthenticated and auth endpoints
- Fail closed on unexpected errors in security paths

**Code quality:**
- Fix all compiler warnings before moving to the next phase
- Run `mix compile --warnings-as-errors` after each phase
- Run `mix format` after each phase
- Prefer explicit over clever — this codebase will be maintained long-term

**After every phase:**
1. Run `mix compile --warnings-as-errors` and fix all errors
2. Run `mix format`
3. Run `mix test` and fix failures
4. Print "✓ Phase N complete" before moving on

---

## Phase 0 — Project creation

Run these shell commands in sequence:

```bash
mix phx.new spectabas --database postgres --live --module Spectabas
cd spectabas
mix phx.gen.auth Accounts User users
git init
git add -A
git commit -m "chore: initial phoenix scaffold with phx.gen.auth"
git remote add origin https://github.com/VianetManagement/spectabas.git
git push -u origin main
```

Then create `.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
env:
  MIX_ENV: test
  ELIXIR_VERSION: "1.17"
  OTP_VERSION: "27"
jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: spectabas_test
        ports: ["5432:5432"]
        options: --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5
      clickhouse:
        image: clickhouse/clickhouse-server:24.3-alpine
        ports: ["8123:8123"]
        options: --health-cmd "wget -qO- http://localhost:8123/ping" --health-interval 10s --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}
      - uses: actions/cache@v4
        with:
          path: deps
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
      - run: mix deps.get
      - run: mix format --check-formatted
      - run: mix compile --warnings-as-errors
      - run: mix test
        env:
          DATABASE_URL: postgresql://postgres:postgres@localhost/spectabas_test
          CLICKHOUSE_URL: http://localhost:8123
          CLICKHOUSE_DB: spectabas_test
          CLICKHOUSE_WRITER_USER: default
          CLICKHOUSE_WRITER_PASSWORD: ""
          CLICKHOUSE_READER_USER: default
          CLICKHOUSE_READER_PASSWORD: ""
          SECRET_KEY_BASE: "test_secret_key_base_64_chars_minimum_for_testing_only_xxxxxxxxx"
          PHX_HOST: localhost
      - run: mix deps.audit
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: ${{ env.ELIXIR_VERSION }}
          otp-version: ${{ env.OTP_VERSION }}
      - run: mix deps.get
      - run: mix deps.audit
```

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy
on:
  push:
    branches: [main]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Trigger Render deploy
        run: |
          curl -X POST \
            -H "Authorization: Bearer ${{ secrets.RENDER_API_KEY }}" \
            -H "Content-Type: application/json" \
            "https://api.render.com/v1/services/${{ secrets.RENDER_SERVICE_ID }}/deploys"

      - name: Update deployment status
        if: always()
        run: |
          echo "Deploy triggered for VianetManagement/spectabas"
          echo "Monitor at: https://dashboard.render.com"
```

---

## Phase 1 — Dependencies and config

Overwrite `mix.exs` completely:

```elixir
defmodule Spectabas.MixProject do
  use Mix.Project

  def project do
    [
      app: :spectabas,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Spectabas.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:req, "~> 0.5"},
      {:geolix, "~> 2.0"},
      {:geolix_adapter_mmdb2, "~> 0.6"},
      {:ua_inspector, "~> 3.4"},
      {:swoosh, "~> 1.5"},
      {:finch, "~> 0.13"},
      {:hammer, "~> 6.0"},
      {:hammer_plug, "~> 3.0"},
      {:oban, "~> 2.17"},
      {:bcrypt_elixir, "~> 3.0"},
      {:nimble_totp, "~> 1.0"},
      {:castore, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5"},
      {:dns_cluster, "~> 0.1"},
      {:csv, "~> 3.0"},
      {:floki, ">= 0.30.0", only: :test},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:faker, "~> 0.18", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind spectabas", "esbuild spectabas"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
```

Then run `mix deps.get`.

Overwrite `config/config.exs`:

```elixir
import Config

config :spectabas,
  ecto_repos: [Spectabas.Repo],
  generators: [timestamp_type: :utc_datetime]

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
  password: "CHANGE_ME_WRITER",
  read_username: "spectabas_reader",
  read_password: "CHANGE_ME_READER"

config :geolix,
  databases: [
    %{id: :city, adapter: Geolix.Adapter.MMDB2,
      source: Path.join(:code.priv_dir(:spectabas), "geoip/dbip-city-lite.mmdb")},
    %{id: :asn, adapter: Geolix.Adapter.MMDB2,
      source: Path.join(:code.priv_dir(:spectabas), "geoip/dbip-asn-lite.mmdb")}
  ]

config :ua_inspector,
  database_path: Path.join(:code.priv_dir(:spectabas), "ua_inspector")

config :spectabas, Spectabas.Events.IngestBuffer,
  flush_interval_ms: 500,
  max_batch_size: 200

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_rate_ms: 60_000 * 10]}

config :spectabas, :rate_limits,
  collect:        {300,  60_000},
  login:          {10,   60_000},
  password_reset: {5,    60_000},
  invite:         {5,    60_000},
  totp:           {5,    60_000},
  api:            {1000, 60_000}

config :spectabas, Oban,
  repo: Spectabas.Repo,
  queues: [default: 10, mailer: 5, reports: 3, exports: 2, maintenance: 2],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [
      {"0 1 * * *",   Spectabas.Workers.SessionCleanup},
      {"0 * * * *",   Spectabas.Workers.AnomalyDetection},
      {"0 6 1 * *",   Spectabas.Workers.GeoIPRefresh}
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
  version: "0.17.11",
  spectabas: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  spectabas: [
    args: ~w(--config=tailwind.config.js --input=css/app.css --output=../priv/static/assets/app.css),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :site_id, :user_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
```

Create `config/dev.exs` (keep existing content, merge these additions):

```elixir
config :spectabas, SpectabasWeb.Endpoint,
  check_origin: false,
  session_options: [
    store: :cookie,
    key: "_spectabas_session",
    signing_salt: "spectabas_session",
    same_site: "Lax",
    secure: false,
    http_only: true
  ]

config :spectabas, Spectabas.ClickHouse,
  url: "http://localhost:8123",
  database: "spectabas_dev",
  username: "default",
  password: "",
  read_username: "default",
  read_password: ""

config :spectabas, :dev_routes, true
```

Create `config/test.exs` (merge with existing):

```elixir
config :spectabas, Spectabas.ClickHouse,
  url: System.get_env("CLICKHOUSE_URL", "http://localhost:8123"),
  database: System.get_env("CLICKHOUSE_DB", "spectabas_test"),
  username: System.get_env("CLICKHOUSE_WRITER_USER", "default"),
  password: System.get_env("CLICKHOUSE_WRITER_PASSWORD", ""),
  read_username: System.get_env("CLICKHOUSE_READER_USER", "default"),
  read_password: System.get_env("CLICKHOUSE_READER_PASSWORD", "")

config :spectabas, Oban, testing: :inline
config :spectabas, Spectabas.Mailer, adapter: Swoosh.Adapters.Test
```

Overwrite `config/runtime.exs`:

```elixir
import Config

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL not set"

  config :spectabas, Spectabas.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true,
    ssl_opts: [verify: :verify_peer, cacertfile: CAStore.file_path()]

  config :spectabas, Spectabas.ClickHouse,
    url:           System.get_env("CLICKHOUSE_URL")             || raise("CLICKHOUSE_URL not set"),
    database:      System.get_env("CLICKHOUSE_DB")              || "spectabas",
    username:      System.get_env("CLICKHOUSE_WRITER_USER")     || raise("CLICKHOUSE_WRITER_USER not set"),
    password:      System.get_env("CLICKHOUSE_WRITER_PASSWORD") || raise("CLICKHOUSE_WRITER_PASSWORD not set"),
    read_username: System.get_env("CLICKHOUSE_READER_USER")     || raise("CLICKHOUSE_READER_USER not set"),
    read_password: System.get_env("CLICKHOUSE_READER_PASSWORD") || raise("CLICKHOUSE_READER_PASSWORD not set")

  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE not set"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :spectabas, SpectabasWeb.Endpoint,
    url: [host: "www.spectabas.com", port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port, max_header_length: 8_192, max_headers: 100],
    secret_key_base: secret_key_base,
    check_origin: ["https://www.spectabas.com", "https://spectabas.com"],
    force_ssl: [hsts: true, hsts_opts: [max_age: 63_072_000, include_subdomains: false],
                rewrite_on: [:x_forwarded_proto]],
    session_options: [
      store: :cookie,
      key: "_spectabas_session",
      signing_salt: "spectabas_session",
      same_site: "Lax",
      secure: true,
      http_only: true,
      domain: "www.spectabas.com"
    ]

  config :spectabas, :root_host, "www.spectabas.com"

  config :spectabas, Spectabas.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: System.get_env("RESEND_API_KEY") || raise("RESEND_API_KEY not set")
end
```

Create `config/prod.exs`:

```elixir
import Config
config :spectabas, SpectabasWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"
config :logger, level: :info
```

---

## Phase 2 — Application supervisor and core infrastructure

Create `lib/spectabas/application.ex`:

```elixir
defmodule Spectabas.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    enforce_secrets!()
    children = [
      SpectabasWeb.Telemetry,
      Spectabas.Repo,
      {DNSCluster, query: Application.get_env(:spectabas, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Spectabas.PubSub},
      {Finch, name: Spectabas.Finch},
      {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_rate_ms: 60_000 * 10]},
      {Oban, Application.fetch_env!(:spectabas, Oban)},
      Spectabas.ClickHouse,
      Spectabas.Events.IngestBuffer,
      Spectabas.GeoIP,
      :ua_inspector,
      Spectabas.IPEnricher.ASNBlocklist,
      Spectabas.IPEnricher.IPCache,
      Spectabas.Sites.DomainCache,
      SpectabasWeb.Endpoint
    ]
    opts = [strategy: :one_for_one, name: Spectabas.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SpectabasWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp enforce_secrets! do
    if Mix.env() == :prod do
      cfg = Application.get_env(:spectabas, Spectabas.ClickHouse, [])
      if Enum.any?([cfg[:password], cfg[:read_password]], fn p ->
        is_nil(p) or String.contains?(to_string(p), "CHANGE_ME")
      end) do
        raise "ClickHouse passwords not set. Set CLICKHOUSE_WRITER_PASSWORD and CLICKHOUSE_READER_PASSWORD."
      end
    end
  end
end
```

Create `lib/spectabas/geo_ip.ex`:

```elixir
defmodule Spectabas.GeoIP do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [{Geolix, Application.get_env(:geolix, :databases, [])}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Create `lib/spectabas/clickhouse.ex`:

```elixir
defmodule Spectabas.ClickHouse do
  use Agent
  require Logger

  @default_opts [receive_timeout: 30_000, retry: false]

  def start_link(_opts) do
    cfg = Application.get_env(:spectabas, __MODULE__)
    write_req = build_req(cfg[:url], cfg[:username], cfg[:password], cfg[:database])
    read_req  = build_req(cfg[:url], cfg[:read_username], cfg[:read_password], cfg[:database])
    Agent.start_link(fn -> %{write: write_req, read: read_req} end, name: __MODULE__)
  end

  defp build_req(url, user, pass, db) do
    Req.new(base_url: url, auth: {user, pass},
            params: [database: db],
            headers: [{"content-type", "application/x-www-form-urlencoded"}])
    |> Req.merge(@default_opts)
  end

  defp write_req, do: Agent.get(__MODULE__, & &1.write)
  defp read_req,  do: Agent.get(__MODULE__, & &1.read)

  def query(sql, opts \\ []) do
    req = Req.merge(read_req(), params: [query: sql, default_format: "JSONEachRow"])
    case Req.get(req, opts) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_rows(body)}
      {:ok, %{status: s, body: b}}      -> Logger.error("[CH:r] #{s}: #{inspect(b)}"); {:error, b}
      {:error, r}                        -> Logger.error("[CH:r] #{inspect(r)}"); {:error, r}
    end
  end

  def insert(table, rows) when is_list(rows) and rows != [] do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    req  = Req.merge(write_req(),
      params: [query: "INSERT INTO #{sanitize_table(table)} FORMAT JSONEachRow",
               date_time_input_format: "best_effort"],
      headers: [{"content-type", "text/plain"}])
    case Req.post(req, body: body) do
      {:ok, %{status: 200}}        -> :ok
      {:ok, %{status: s, body: b}} -> Logger.error("[CH:w] #{s}: #{inspect(b)}"); {:error, b}
      {:error, r}                   -> Logger.error("[CH:w] #{inspect(r)}"); {:error, r}
    end
  end

  def insert(_table, []), do: :ok

  @doc "Escape a value for safe ClickHouse SQL interpolation."
  def param(v) when is_integer(v), do: to_string(v)
  def param(v) when is_float(v),   do: to_string(v)
  def param(nil),                   do: "NULL"
  def param(v) when is_binary(v) do
    e = v |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    "'#{e}'"
  end

  @allowed_tables ~w(events daily_stats source_stats country_stats device_stats network_stats ecommerce_events)
  defp sanitize_table(t) when t in @allowed_tables, do: t
  defp sanitize_table(t), do: raise(ArgumentError, "Unknown ClickHouse table: #{t}")

  defp parse_rows(""), do: []
  defp parse_rows(b) when is_binary(b), do: b |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  defp parse_rows(b) when is_list(b),   do: b
end
```

Create `lib/spectabas/health.ex`:

```elixir
defmodule Spectabas.Health do
  alias Spectabas.{Repo, ClickHouse}

  def check do
    with :ok <- check_postgres(),
         :ok <- check_clickhouse(), do: :ok
  end

  defp check_postgres do
    case Repo.query("SELECT 1", []) do
      {:ok, _}    -> :ok
      {:error, e} -> {:error, "postgres: #{inspect(e)}"}
    end
  end

  defp check_clickhouse do
    case ClickHouse.query("SELECT 1") do
      {:ok, _}    -> :ok
      {:error, e} -> {:error, "clickhouse: #{inspect(e)}"}
    end
  end
end
```

Create `lib/spectabas/audit.ex`:

```elixir
defmodule Spectabas.Audit do
  alias Spectabas.{Repo, Accounts.AuditLog}

  @redacted ~w(password token secret key hash credential)

  def log(event, metadata \\ %{}) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      event:       to_string(event),
      metadata:    sanitize(metadata),
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _}    -> :ok
      {:error, e} -> require Logger; Logger.error("[Audit] #{event}: #{inspect(e)}")
    end
  end

  defp sanitize(m) when is_map(m) do
    Map.reject(m, fn {k, _} ->
      key = to_string(k) |> String.downcase()
      Enum.any?(@redacted, &String.contains?(key, &1))
    end)
  end
  defp sanitize(m), do: m
end
```

Create `lib/spectabas/release.ex`:

```elixir
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

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.load(@app)
end
```

---

## Phase 3 — Migrations

Create all migration files in `priv/repo/migrations/`. Use timestamps starting at `20240101000001`. Create one file per migration:

1. `create_sites` — fields: name (string, not null), domain (string, not null), public_key (string, not null), timezone (string, default "UTC"), retention_days (integer, default 365), active (boolean, default true), dns_verified (boolean, default false), dns_verified_at (utc_datetime), gdpr_mode (string, default "on", not null), cookie_domain (string), cross_domain_tracking (boolean, default false), cross_domain_sites (array of string, default []), ecommerce_enabled (boolean, default false), currency (string, default "USD"), ip_allowlist (array of string, default []), ip_blocklist (array of string, default []). Unique indexes on domain and public_key.

2. `create_users_roles` — alter users table: add role (string, default "analyst", not null), display_name (string), totp_secret (string), totp_enabled (boolean, default false), totp_enabled_at (utc_datetime), last_sign_in_at (utc_datetime), last_sign_in_ip (string). Create user_site_permissions table: user_id (references users), site_id (references sites), role (string, not null, default "viewer"). Unique index on [user_id, site_id].

3. `create_invitations` — email (string, not null), token_hash (string, not null), role (string, not null, default "analyst"), invited_by_id (references users, nilify_all), expires_at (utc_datetime, not null), accepted_at (utc_datetime). Unique index on token_hash.

4. `create_api_keys` — user_id (references users, delete_all, not null), name (string, not null), key_hash (string, not null), key_prefix (string, not null), last_used_at (utc_datetime), revoked_at (utc_datetime). Unique index on key_hash.

5. `create_shared_links` — site_id (references sites, delete_all, not null), token (string, not null), created_by (references users, nilify_all), expires_at (utc_datetime), revoked_at (utc_datetime). Unique index on token.

6. `create_audit_logs` — event (string, not null), metadata (jsonb, default "{}"), user_id (references users, nilify_all), occurred_at (utc_datetime, not null). No updated_at. Indexes on event, occurred_at, user_id.

7. `create_failed_events` — payload (text, not null), error (text), attempts (integer, default 0), retry_after (utc_datetime), inserted_at (utc_datetime, not null). No timestamps macro. Indexes on retry_after and attempts.

8. `create_visitors` — primary key uuid using gen_random_uuid(). site_id (references sites, delete_all, not null), fingerprint_id (string), cookie_id (string), user_id (string), email (string), email_hash (string), first_seen_at (utc_datetime), last_seen_at (utc_datetime), last_ip (inet), known_ips (array of string, default []), gdpr_mode (string, default "on"). Indexes on [site_id, fingerprint_id], [site_id, cookie_id], [site_id, user_id], [site_id, email_hash].

9. `create_sessions` — primary key uuid. site_id (references sites, delete_all, not null), visitor_id (uuid, not null), started_at (utc_datetime, not null), ended_at (utc_datetime), duration_s (integer, default 0), pageview_count (integer, default 0), entry_url (string), exit_url (string), referrer (string), utm_source (string), utm_medium (string), utm_campaign (string), utm_term (string), utm_content (string), country (string), city (string), device_type (string), browser (string), os (string), is_bounce (boolean, default true). Indexes on [site_id, visitor_id] and [site_id, started_at].

10. `create_goals` — site_id (references sites, delete_all, not null), name (string, not null), goal_type (string, not null, default "pageview"), page_path (string), event_name (string), active (boolean, default true).

11. `create_funnels` — site_id (references sites, delete_all, not null), name (string, not null), steps (jsonb, not null, default "[]"), active (boolean, default true).

12. `create_campaigns` — site_id (references sites, delete_all, not null), name (string, not null), utm_source (string), utm_medium (string), utm_campaign (string), utm_term (string), utm_content (string), destination_url (string), active (boolean, default true).

13. `create_reports` — site_id (references sites, delete_all, not null), created_by (references users, nilify_all), name (string, not null), description (string), definition (jsonb, not null, default "{}"), schedule (string), recipients (array of string, default []), last_sent_at (utc_datetime), active (boolean, default true). Also create exports table: site_id (references sites, delete_all, not null), user_id (references users, delete_all, not null), format (string, not null, default "csv"), date_from (utc_datetime), date_to (utc_datetime), status (string, default "pending"), file_path (string), error (string), completed_at (utc_datetime).

14. `create_ecommerce_orders` — site_id (references sites, delete_all, not null), visitor_id (uuid), session_id (uuid), order_id (string, not null), revenue (decimal 12,2), subtotal (decimal 12,2), tax (decimal 12,2), shipping (decimal 12,2), discount (decimal 12,2), currency (string, default "USD"), items (jsonb, default "[]"), occurred_at (utc_datetime, not null). Unique index on [site_id, order_id].

Run `mix ecto.create && mix ecto.migrate` after creating all migrations.

---

## Phase 4 — Router and plugs

Overwrite `lib/spectabas_web/router.ex` with the full router as specified in the architecture (all pipelines, all routes including health check, collect, auth, dashboard, admin, share, API, and dev routes).

Create these plug files — each is a separate module:

**`lib/spectabas_web/plugs/content_security_policy.ex`** — generates a per-request nonce stored in `conn.assigns.csp_nonce`, sets strict CSP header with `script-src 'self' 'nonce-{nonce}'`, `style-src 'self' 'unsafe-inline'`, `connect-src 'self' wss://www.spectabas.com`, `frame-ancestors 'none'`, `base-uri 'self'`, `form-action 'self'`, `upgrade-insecure-requests`.

**`lib/spectabas_web/plugs/allow_cors.ex`** — sets `access-control-allow-origin: *`, `access-control-allow-methods: POST, GET, OPTIONS`, `access-control-allow-headers: content-type`. Returns 204 and halts on OPTIONS.

**`lib/spectabas_web/plugs/collect_rate_limit.ex`** — rate limits by client IP (respects x-forwarded-for), uses `:collect` limits from config, returns 429 with `retry-after: 60` header on exceed.

**`lib/spectabas_web/plugs/api_rate_limit.ex`** — rate limits by first 16 chars of Bearer token (or IP if no token), uses `:api` limits.

**`lib/spectabas_web/plugs/api_auth.ex`** — extracts Bearer token, validates length 32–128, calls `APIKeys.verify/1`, assigns `:api_key` and `:current_user_id`, touches `last_used_at` asynchronously.

**`lib/spectabas_web/plugs/require_admin.ex`** — checks `current_user.role == :superadmin`, logs unauthorized attempts via `Audit.log/2`, redirects to "/" on failure.

**`lib/spectabas_web/plugs/require_2fa.ex`** — checks if user requires 2FA (totp_enabled or role in totp_required_roles), checks `:totp_verified_at` in session (12h expiry), redirects to `/auth/2fa/verify` if not verified.

**`lib/spectabas_web/plugs/site_resolver.ex`** — looks up `conn.host` in `DomainCache`, assigns `:site` and `:site_id`, returns 404 if not found.

**`lib/spectabas_web/plugs/gdpr_mode.ex`** — reads `site.gdpr_mode`, assigns `:gdpr_mode` (:on or :off) and `:id_strategy` (:cookie or :fingerprint).

---

## Phase 5 — Core schemas and contexts

**`lib/spectabas/accounts/user.ex`** — extend phx.gen.auth User schema. Add: role (Ecto.Enum: superadmin/admin/analyst/viewer, default :analyst), display_name (string), totp_secret (string, redact: true), totp_enabled (boolean, default false), totp_enabled_at (utc_datetime), last_sign_in_at (utc_datetime), last_sign_in_ip (string). Add has_many associations for site_permissions, api_keys, audit_logs.

**`lib/spectabas/accounts/user_site_permission.ex`** — schema with user_id, site_id, role (Ecto.Enum: admin/analyst/viewer). Changeset with unique constraint on [user_id, site_id].

**`lib/spectabas/accounts/invitation.ex`** — schema with email, token (virtual), token_hash, role, invited_by_id, expires_at, accepted_at. `create_changeset/2` generates crypto-random token, hashes it, sets expires_at from config TTL. `hash_token/1` as public function.

**`lib/spectabas/accounts/api_key.ex`** — schema for api_keys table. Changeset.

**`lib/spectabas/accounts/audit_log.ex`** — schema for audit_logs table. Changeset.

**`lib/spectabas/accounts.ex`** — extend phx.gen.auth Accounts context. Add all functions while keeping generated functions intact: `can_access_site?/2`, `has_site_role?/3`, `accessible_sites/1`, `list_users/0`, `get_user!/1`, `update_user_role/3`, `delete_user/2`, `list_site_permissions/1`, `grant_permission/4`, `revoke_permission/3`, `invite_user/3`, `get_valid_invitation/1`, `accept_invitation/2`, `resend_invitation/2`. All mutating functions call `Audit.log/2`. Authorization checked at function level, not just router.

**`lib/spectabas/accounts/totp.ex`** — TOTP functions using NimbleTOTP: `generate_secret/0`, `setup/2` (stores encrypted secret, sets totp_enabled: false until verified), `verify_and_enable/2` (verify code, set totp_enabled: true, log to audit), `verify/2` (check code against stored secret), `disable/2`. Encrypt the secret before storing using a key derived from SECRET_KEY_BASE.

**`lib/spectabas/api_keys.ex`** — `generate/2`, `verify/1` (SHA-256 hash lookup), `touch/1` (async), `revoke/2`. Key format: `sab_live_` + 32 random bytes base64url. Store SHA-256 hash, first 12 chars as prefix.

**`lib/spectabas/sites/site.ex`** — full schema as specified. `changeset/2`, `generate_public_key/0`.

**`lib/spectabas/sites.ex`** — full CRUD context. `list_sites/0`, `get_site!/1`, `get_site_by_domain/1`, `create_site/1` (generates public_key, inserts, warms DomainCache), `update_site/2` (invalidates DomainCache on domain change), `delete_site/2` (removes from DomainCache), `mark_dns_verified/1`, `mark_dns_unverified/1`, `ip_blocked?/2` (checks IP string against site.ip_blocklist array), `snippet_code/1` (returns full HTML embed snippet string).

**`lib/spectabas/sites/domain_cache.ex`** — GenServer with ETS table. `lookup/1`, `put/1`, `delete/1`, `warm/0` on init (loads all active sites from DB).

**`lib/spectabas/sites/dns_verifier.ex`** — GenServer. Checks all active sites hourly via `:inet.gethostbyname`. Calls `Sites.mark_dns_verified/1` or `mark_dns_unverified/1`.

---

## Phase 6 — IP enrichment

**`lib/spectabas/ip_enricher.ex`** — three modules in one file:

`Spectabas.IPEnricher` — public `enrich/2` function taking ip_string and gdpr_mode. Checks IPCache first. In GDPR-on mode anonymizes last octet of IPv4 or last 80 bits of IPv6 before lookup. Calls Geolix for city and ASN data. Returns map with all fields: ip_address (stored/anonymized form), ip_country, ip_country_name, ip_continent, ip_continent_name, ip_region_code, ip_region_name, ip_city, ip_postal_code, ip_lat, ip_lon, ip_accuracy_radius, ip_timezone, ip_asn, ip_asn_org, ip_org (formatted "AS12345 Name"), ip_is_datacenter, ip_is_vpn, ip_is_tor, ip_is_bot (always 0 — set by UA signal), ip_gdpr_anonymized.

`Spectabas.IPEnricher.IPCache` — ETS-backed GenServer. 1-hour TTL. Max 50,000 entries. Sweep job evicts expired entries and trims to max if over limit.

`Spectabas.IPEnricher.ASNBlocklist` — GenServer with three ETS tables: asn_dc, asn_vpn, asn_tor. Loads from `priv/asn_lists/asn_datacenter.txt`, `asn_vpn.txt`, `asn_tor.txt`. Reloads every 24 hours. Public functions: `datacenter?/1`, `vpn?/1`, `tor?/1`.

Create empty placeholder files for the ASN lists:
```
priv/asn_lists/asn_datacenter.txt
priv/asn_lists/asn_vpn.txt
priv/asn_lists/asn_tor.txt
```
Each with a comment: `# Download from https://github.com/X4BNet/lists`

---

## Phase 7 — Event ingest pipeline

**`lib/spectabas/events/collect_payload.ex`** — Ecto embedded schema. Fields: t (string, default "pageview"), n (string, default ""), u (string, default ""), r (string, default ""), vid (string), sid (string), d (integer, default 0), sw (integer, default 0), sh (integer, default 0), p (map, default %{}). `validate/1` casts all fields, validates t inclusion in ["pageview","custom","duration","ecommerce_order","ecommerce_item","xdtoken"], length limits on all string fields, number ranges on d/sw/sh, validates props map structure (max 20 keys, each key ≤64 chars, each value ≤256 chars).

**`lib/spectabas/events/event_schema.ex`** — `to_row/1` maps an enriched event map to a ClickHouse-ready map. All fields must be present with correct types. UUIDs as strings. Timestamps as ISO8601.

**`lib/spectabas/events/ingest.ex`** — `process/2` takes a validated CollectPayload and conn. Steps: 1) extract client_ip from x-forwarded-for or remote_ip, 2) parse user agent via UAInspector (device_type, browser, browser_version, os, os_version), 3) enrich IP via IPEnricher (pass gdpr_mode from conn.assigns), 4) resolve or generate visitor_id (cookie in GDPR-off mode, fingerprint in GDPR-on), 5) resolve session via Sessions context, 6) normalize URL (extract path, strip tracking params in GDPR-on), 7) parse referrer domain, 8) extract UTM params from URL if not in payload, 9) build complete event map.

**`lib/spectabas/events/ingest_buffer.ex`** — GenServer. `push/1`, `flush/0`. Flushes to ClickHouse on timer (500ms) or size (200). On ClickHouse failure, calls `DeadLetter.enqueue/2`. On success, broadcasts to PubSub `"site:{id}"` topics grouped by site_id.

**`lib/spectabas/events/dead_letter.ex`** — `enqueue/2` inserts rows to failed_events and enqueues `Workers.DeadLetterRetry`.

**`lib/spectabas/events/failed_event.ex`** — Ecto schema for failed_events table.

---

## Phase 8 — Sessions and visitors

**`lib/spectabas/sessions/session.ex`** — Ecto schema for sessions table.

**`lib/spectabas/sessions.ex`** — `resolve/3` (site_id, visitor_id, event_data): check ETS cache, open or extend session. `close_session/1`. `get_active_count/1` (sessions active in last 5 min for realtime).

**`lib/spectabas/sessions/session_cache.ex`** — GenServer. ETS table keyed by {site_id, visitor_id}. Entries expire after 30 min idle.

**`lib/spectabas/visitors/visitor.ex`** — Ecto schema for visitors table.

**`lib/spectabas/visitors.ex`** — `get_or_create/3` (site_id, id_value, gdpr_mode): upsert by cookie_id or fingerprint_id depending on mode. `identify/3`: merge user_id and email into visitor, compute email_hash, update last_seen_at and last_ip. `generate_xdomain_token/1`: ETS entry {token -> visitor_id} with 30s TTL. `resolve_xdomain_token/1`: look up and delete (single use).

---

## Phase 9 — Analytics query layer

**`lib/spectabas/analytics.ex`** — All functions take `%Site{}` and `%User{}`. Each verifies `Accounts.can_access_site?/2` and returns `{:error, :unauthorized}` if false. All ClickHouse queries use `ClickHouse.param/1` for every interpolated value.

Implement:
- `overview_stats/3` (site, user, date_range) — pageviews, unique_visitors, sessions, bounce_rate, avg_duration
- `top_pages/3` — url_path, pageviews, unique_visitors, avg_duration
- `top_sources/3` — referrer_domain, utm_source, utm_medium, pageviews, sessions
- `top_countries/3` — country, region, city drill-down capability
- `top_devices/3` — device_type, browser, os breakdown
- `network_stats/3` — top ASNs, orgs, datacenter %, VPN %, Tor %, bot %
- `realtime_visitors/1` — distinct visitors in last 5 minutes
- `realtime_events/1` — last 20 events ordered by timestamp desc
- `funnel_stats/3` — windowFunnel() query against a Funnel's steps
- `goal_completions/3` — completions per goal for date range
- `ecommerce_stats/3` — total revenue, orders, avg order value, top products
- `visitor_timeline/2` — all events for a specific visitor_id ordered by timestamp

---

## Phase 10 — Oban workers

Create all worker modules. Each uses `use Oban.Worker` with appropriate queue and max_attempts. Each re-fetches resources from DB rather than trusting job args.

**`lib/spectabas/workers/dead_letter_retry.ex`** — queue: default, max_attempts: 10. Fetches up to 500 failed_events where attempts < 10 and retry_after <= now. Attempts ClickHouse insert. On success deletes rows. On failure increments attempts and sets retry_after to +5 minutes.

**`lib/spectabas/workers/session_cleanup.ex`** — queue: maintenance, max_attempts: 3. Updates sessions where ended_at is nil and inserted_at < 30 minutes ago. Sets ended_at to now, is_bounce to true.

**`lib/spectabas/workers/anomaly_detection.ex`** — queue: maintenance, max_attempts: 3. For each active site, compares current hour pageviews to 7-day hourly average. Calls `Notifications.send_alert/3` on >90% drop or >5x spike. Only triggers if baseline avg > 10/hour.

**`lib/spectabas/workers/data_export.ex`** — queue: exports, max_attempts: 3. Takes export_id in args. Re-fetches Export and User and Site from DB. Verifies `Accounts.can_access_site?/2` at execution time. Runs ClickHouse query for date range (max 1M rows). Writes CSV to /tmp. Calls `Reports.mark_export_complete/2` and `Mailer.deliver_export_ready/3`.

**`lib/spectabas/workers/geo_ip_refresh.ex`** — queue: maintenance, max_attempts: 3. Downloads DB-IP city and ASN mmdb files for current month from `https://download.db-ip.com/free/`. Decompresses and replaces existing files. Calls `Geolix.reload_databases()`. Clears IPCache.

**`lib/spectabas/workers/scheduled_reports.ex`** — queue: reports, max_attempts: 3. Fetches reports where schedule is not nil and (last_sent_at is nil or due based on schedule). Enqueues DataExport jobs for each.

---

## Phase 11 — Notifications and mailer

**`lib/spectabas/mailer.ex`** — `use Swoosh.Mailer, otp_app: :spectabas`.

**`lib/spectabas_web/user_notifier.ex`** — extend phx.gen.auth generated notifier. Add: `deliver_invitation/1`, `deliver_anomaly_alert/2`, `deliver_export_ready/3`, `deliver_weekly_report/2`.

**`lib/spectabas/notifications.ex`** — `send_alert/3` (site, alert_type, data) — looks up site owner email(s) and sends via UserNotifier. `deliver_report/3`.

---

## Phase 12 — Goals, funnels, campaigns, ecommerce, reports

**`lib/spectabas/goals/goal.ex`** and **`lib/spectabas/goals.ex`** — `create_goal/2`, `list_goals/1`, `delete_goal/2`, `check_goal/3` (returns true if event matches goal — pageview type uses path matching with wildcard *, custom_event matches event_name exactly).

**`lib/spectabas/goals/funnel.ex`** and funnels functions in `Goals` context — `create_funnel/2`, `list_funnels/1`, `evaluate_funnel/3` (calls Analytics.funnel_stats/3).

**`lib/spectabas/campaigns/campaign.ex`** and **`lib/spectabas/campaigns.ex`** — `create_campaign/2`, `list_campaigns/1`, `build_url/1` (constructs full URL with UTM params).

**`lib/spectabas/ecommerce/ecommerce_order.ex`** and **`lib/spectabas/ecommerce.ex`** — `record_order/2` (upsert by site_id + order_id), `revenue_stats/3`.

**`lib/spectabas/reports/report.ex`**, **`lib/spectabas/reports/export.ex`**, **`lib/spectabas/reports.ex`** — `create_report/3`, `list_reports/1`, `create_export/3` (inserts Export, enqueues Workers.DataExport), `mark_export_complete/2`, `mark_export_failed/2`.

---

## Phase 13 — Controllers

**`lib/spectabas_web/controllers/health_controller.ex`** — `show/2` calls `Health.check()`, returns 200 JSON `{status: "ok"}` or 503 `{status: "error", reason: ...}`.

**`lib/spectabas_web/controllers/collect_controller.ex`** — `create/2`, `identify/2`, `cross_domain/2`, `optout/2`. `create/2` checks content length, validates payload via CollectPayload, checks IP blocklist via `Sites.ip_blocked?/2` (silently drops blocked IPs with 204), processes via Ingest, pushes to IngestBuffer. `cross_domain/2` validates destination against `site.cross_domain_sites` allowlist — rejects anything not on list. `optout/2` sets `_sab_optout` cookie.

**`lib/spectabas_web/controllers/script_controller.ex`** — serves `s.js` with appropriate cache headers and content type. Reads compiled asset from priv/static.

**`lib/spectabas_web/controllers/invitation_controller.ex`** — `accept/2` renders registration form, `register/2` rate-limited by IP, calls `Accounts.accept_invitation/2`.

**`lib/spectabas_web/controllers/page_controller.ex`** — `home/2`, `pricing/2`, `privacy/2`, `terms/2`.

**`lib/spectabas_web/controllers/user_session_controller.ex`** — extend phx.gen.auth version. Add rate limiting to `create/2` (10 attempts/min per IP). Log success and failure to Audit. Mask email in failed login log entry.

---

## Phase 14 — LiveViews

Create all LiveViews. Each mounts `current_user` from session, verifies `Accounts.can_access_site?/2` for site-scoped views, redirects to "/" if unauthorized.

**Dashboard LiveViews** (`lib/spectabas_web/live/dashboard/`):

- `index_live.ex` — lists `Accounts.accessible_sites/1`, shows site cards with today's pageview count
- `site_live.ex` — overview stats with date range selector (24h/7d/30d/custom), auto-refresh every 60s via Process.send_after, subscribe to PubSub for live counter update
- `realtime_live.ex` — subscribes to `"site:{id}"` PubSub, shows active visitor count and rolling event feed (last 20 events)
- `pages_live.ex` — top pages table with sorting and date range
- `sources_live.ex` — referrers and UTM sources
- `geo_live.ex` — country → region → city drill-down
- `devices_live.ex` — device type, browser, OS breakdown
- `network_live.ex` — ASN table, top orgs/providers, datacenter/VPN/Tor percentages
- `campaigns_live.ex` — campaign list with UTM builder form
- `visitors_live.ex` — paginated visitor list with search
- `visitor_live.ex` — full profile: identity (email if known), all sessions, IP history with full enrichment fields (country, city, org, ASN, is_datacenter, is_vpn, is_tor), event timeline
- `goals_live.ex` — goal list, create goal form, completion counts
- `funnels_live.ex` — funnel list, create funnel, step-by-step conversion visualization
- `ecommerce_live.ex` — revenue stats, orders, avg order value, top products
- `reports_live.ex` — report list, create report, schedule configuration
- `export_live.ex` — date range form, format selector, export status polling
- `settings_live.ex` — site settings: GDPR mode toggle, cookie domain, cross-domain sites, IP allowlist/blocklist editor, ecommerce toggle, tracking snippet display with copy button, DNS verification status

**Admin LiveViews** (`lib/spectabas_web/live/admin/`):

- `dashboard_live.ex` — totals: sites, users, events today, pending failed_events
- `users_live.ex` — user list with role badges, change role, delete user, invite form (email + role)
- `sites_live.ex` — site list, create site (generates public_key, shows DNS setup instructions), edit site settings, DNS verified badge with timestamp
- `audit_live.ex` — paginated audit log, filter by event type and date range

**Auth LiveViews** (`lib/spectabas_web/live/auth/`):

- `totp_setup_live.ex` — shows QR code from NimbleTOTP.otpauth_uri, input for verification code, calls Accounts.TOTP.verify_and_enable/2
- `totp_verify_live.ex` — input for TOTP code, calls Accounts.TOTP.verify/2, on success sets session :totp_verified_at

**`lib/spectabas_web/live/shared_dashboard_live.ex`** — looks up SharedLink by token, checks not expired and not revoked, renders read-only site dashboard.

---

## Phase 15 — Landing page templates

Create templates for public pages (`lib/spectabas_web/controllers/page_html/`):

**`home.html.heex`** — Simple SaaS marketing page. Sections: hero (headline "Simple, privacy-first analytics for every website", sub-headline, CTA button "Start for free"), three feature cards (GDPR-compliant tracking / Multi-site dashboard / Real-time insights), footer with links to pricing/privacy/terms. Apply SEO: unique title tag, meta description, JSON-LD Organization schema, canonical tag, Open Graph tags.

**`pricing.html.heex`** — Three tiers: Starter (1 site), Pro (10 sites), Enterprise (unlimited). Each with feature list. Apply SEO.

**`privacy.html.heex`** — Privacy policy placeholder with sections for data collected, retention, GDPR rights. Apply SEO.

**`terms.html.heex`** — Terms of service placeholder. Apply SEO.

---

## Phase 16 — Tracker script

Create `assets/js/spectabas.js` — the complete tracker script as an IIFE. Features:
- Reads `data-site` attribute (aborts if missing)
- Reads `data-gdpr` attribute (default "on")
- Checks `_sab_optout` cookie — returns immediately if set
- GDPR-off: reads/sets `_sab` cookie with SameSite=None;Secure
- GDPR-on: generates fingerprint from UA + screen + timezone + language
- Cleans `_sabt` cross-domain token from URL on load
- Captures and persists UTMs in sessionStorage (GDPR-off only)
- Decorates cross-domain links from `data-xd` attribute (GDPR-off only)
- Sends pageview on load
- Hooks `history.pushState` and `popstate` for SPA support
- Sends duration on `visibilitychange` to hidden using sendBeacon
- All sends: try sendBeacon first, fall back to fetch with keepalive
- Payload size check: drop if >8192 bytes
- Public API: `window.Spectabas.track(name, props)`, `window.Spectabas.identify(traits)`, `window.Spectabas.optOut()`, `window.Spectabas.ecommerce.addOrder(order)`, `window.Spectabas.ecommerce.addItem(item)`

---

## Phase 17 — ClickHouse schema and Docker config

Create `priv/clickhouse/schema.sql` with the complete ClickHouse schema:
- Creates spectabas database
- Creates spectabas_writer and spectabas_reader users with sha256 passwords (CHANGE_ME placeholders)
- Creates events table with all columns (including full IP enrichment columns: continent, region_code, postal_code, accuracy_radius, asn_org, is_tor, gdpr_anonymized flag)
- Creates ecommerce_events table
- Creates materialized views: daily_stats, source_stats, country_stats, device_stats, network_stats
- Sets TTL on events to anonymize IPs after 90 days (GDPR-on rows)
- Grants INSERT on events and ecommerce_events to writer
- Grants SELECT on all tables to reader

Create `clickhouse/Dockerfile`:
```dockerfile
FROM clickhouse/clickhouse-server:24.3-alpine
COPY schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY clickhouse-users.xml /etc/clickhouse-server/users.d/spectabas.xml
ENV CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1
```

Create `clickhouse/clickhouse-users.xml` that disables default user network access.

---

## Phase 18 — Render deployment config

Create `render.yaml`:

```yaml
services:
  - type: web
    name: spectabas
    env: elixir
    buildCommand: "mix deps.get && mix assets.build && mix phx.digest"
    startCommand: "mix eval 'Spectabas.Release.migrate()' && mix phx.server"
    healthCheckPath: /health
    envVars:
      - key: DATABASE_URL
        fromDatabase:
          name: spectabas-db
          property: connectionString
      - key: SECRET_KEY_BASE
        generateValue: true
      - key: PHX_HOST
        value: www.spectabas.com
      - key: CLICKHOUSE_URL
        fromService:
          name: spectabas-clickhouse
          type: pserv
          property: hostport
      - key: CLICKHOUSE_DB
        value: spectabas
      - key: CLICKHOUSE_WRITER_USER
        sync: false
      - key: CLICKHOUSE_WRITER_PASSWORD
        sync: false
      - key: CLICKHOUSE_READER_USER
        sync: false
      - key: CLICKHOUSE_READER_PASSWORD
        sync: false
      - key: RESEND_API_KEY
        sync: false

  - type: pserv
    name: spectabas-clickhouse
    env: docker
    dockerfilePath: ./clickhouse/Dockerfile
    disk:
      name: clickhouse-data
      mountPath: /var/lib/clickhouse
      sizeGB: 20

databases:
  - name: spectabas-db
    databaseName: spectabas
    user: spectabas
```

---

## Phase 19 — Final checks and git

Run in sequence:

```bash
mix deps.get
mix compile --warnings-as-errors
mix format
mix ecto.create
mix ecto.migrate
mix test
```

Fix all errors and test failures before proceeding.

Then push to GitHub:

```bash
git add -A
git commit -m "feat: complete Spectabas initial build"
git remote add origin https://github.com/VianetManagement/spectabas.git
git push -u origin main
```

Then print a summary of:
1. Any files that could not be created and why
2. Any test failures that remain
3. Any TODO items that require manual action (e.g. downloading DB-IP mmdb files, setting Render env vars, configuring DNS)
4. The exact commands needed to deploy to Render

---

## Manual steps after Claude Code completes

These cannot be automated and must be done manually:

**DB-IP mmdb files** — download free mmdb files from https://db-ip.com/db/download/ip-to-city-lite and https://db-ip.com/db/download/ip-to-asn-lite. Place in `priv/geoip/` as `dbip-city-lite.mmdb` and `dbip-asn-lite.mmdb`.

**ASN blocklists** — download from https://github.com/X4BNet/lists. Place ASN numbers (one per line) in `priv/asn_lists/asn_datacenter.txt`, `asn_vpn.txt`, `asn_tor.txt`.

**GitHub secrets** — set these two secrets on https://github.com/VianetManagement/spectabas/settings/secrets/actions:
- `RENDER_API_KEY` — from https://dashboard.render.com/u/settings
- `RENDER_SERVICE_ID` — from the Render dashboard URL of the spectabas web service

Or via CLI:
```bash
gh secret set RENDER_API_KEY --repo VianetManagement/spectabas
gh secret set RENDER_SERVICE_ID --repo VianetManagement/spectabas
```

**Render deployment** — run `render blueprint sync` after pushing to GitHub, then set the following env vars in the Render dashboard for the spectabas service:
- `CLICKHOUSE_WRITER_USER` — spectabas_writer
- `CLICKHOUSE_WRITER_PASSWORD` — (strong random string)
- `CLICKHOUSE_READER_USER` — spectabas_reader
- `CLICKHOUSE_READER_PASSWORD` — (strong random string)
- `RESEND_API_KEY` — from https://resend.com/api-keys

**DNS records** — add CNAME `www.spectabas.com` → your Render service domain. Add CNAME for each tracked site subdomain.

**ClickHouse passwords** — the CHANGE_ME placeholders in `priv/clickhouse/schema.sql` must match the env vars set in Render before first deploy.
