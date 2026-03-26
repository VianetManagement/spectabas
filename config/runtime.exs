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
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # ClickHouse — optional, app starts without it but analytics won't work
  if clickhouse_url = System.get_env("CLICKHOUSE_URL") do
    config :spectabas, Spectabas.ClickHouse,
      url: clickhouse_url,
      database: System.get_env("CLICKHOUSE_DB") || "spectabas",
      username: System.get_env("CLICKHOUSE_WRITER_USER") || "default",
      password: System.get_env("CLICKHOUSE_WRITER_PASSWORD") || "",
      read_username: System.get_env("CLICKHOUSE_READER_USER") || "default",
      read_password: System.get_env("CLICKHOUSE_READER_PASSWORD") || ""
  end

  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE not set"
  host = System.get_env("PHX_HOST") || "www.spectabas.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :spectabas, SpectabasWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    check_origin: [
      "https://#{host}",
      "https://www.spectabas.com",
      "https://spectabas.com",
      "https://spectabas.onrender.com"
    ],
    session_options: [
      store: :cookie,
      key: "_spectabas_session",
      signing_salt: "spectabas_session",
      same_site: "Lax",
      secure: true,
      http_only: true
    ]

  config :spectabas, :root_host, host

  # Mailer — use Resend if key provided, otherwise Local
  if resend_key = System.get_env("RESEND_API_KEY") do
    unless resend_key == "re_placeholder" do
      config :spectabas, Spectabas.Mailer,
        adapter: Swoosh.Adapters.Resend,
        api_key: resend_key

      config :swoosh, api_client: Swoosh.ApiClient.Req
    end
  end
end
