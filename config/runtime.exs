import Config

if System.get_env("PHX_SERVER") do
  config :spectabas, SpectabasWeb.Endpoint, server: true
end

config :spectabas, SpectabasWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL not set"

  config :spectabas, Spectabas.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true,
    ssl_opts: [verify: :verify_peer, cacertfile: CAStore.file_path()]

  config :spectabas, Spectabas.ClickHouse,
    url: System.get_env("CLICKHOUSE_URL") || raise("CLICKHOUSE_URL not set"),
    database: System.get_env("CLICKHOUSE_DB") || "spectabas",
    username: System.get_env("CLICKHOUSE_WRITER_USER") || raise("CLICKHOUSE_WRITER_USER not set"),
    password:
      System.get_env("CLICKHOUSE_WRITER_PASSWORD") || raise("CLICKHOUSE_WRITER_PASSWORD not set"),
    read_username:
      System.get_env("CLICKHOUSE_READER_USER") || raise("CLICKHOUSE_READER_USER not set"),
    read_password:
      System.get_env("CLICKHOUSE_READER_PASSWORD") ||
        raise("CLICKHOUSE_READER_PASSWORD not set")

  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE not set"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :spectabas, SpectabasWeb.Endpoint,
    url: [host: "www.spectabas.com", port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port, max_header_length: 8_192, max_headers: 100],
    secret_key_base: secret_key_base,
    check_origin: ["https://www.spectabas.com", "https://spectabas.com"],
    force_ssl: [
      hsts: true,
      hsts_opts: [max_age: 63_072_000, include_subdomains: false],
      rewrite_on: [:x_forwarded_proto]
    ],
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

  config :swoosh, api_client: Swoosh.ApiClient.Req
end
