defmodule Spectabas.ClickHouse do
  @moduledoc """
  Agent-based ClickHouse HTTP client with separate read/write credentials.

  All user-supplied values interpolated into queries MUST use `param/1`.
  """

  use Agent
  require Logger

  @default_opts [receive_timeout: 30_000, retry: false]

  def start_link(_opts) do
    cfg = Application.get_env(:spectabas, __MODULE__)
    ensure_schema!(cfg)
    write_req = build_req(cfg[:url], cfg[:username], cfg[:password], cfg[:database])
    read_req = build_req(cfg[:url], cfg[:read_username], cfg[:read_password], cfg[:database])
    Agent.start_link(fn -> %{write: write_req, read: read_req} end, name: __MODULE__)
  end

  defp ensure_schema!(cfg) do
    # Use default user to create database and tables if they don't exist
    admin_req =
      Req.new(
        base_url: cfg[:url],
        auth: {:basic, "default:"},
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )
      |> Req.merge(@default_opts)

    db = cfg[:database] || "spectabas"

    statements = [
      "CREATE DATABASE IF NOT EXISTS #{db}",
      """
      CREATE TABLE IF NOT EXISTS #{db}.events (
        event_id UUID DEFAULT generateUUIDv4(),
        site_id UInt64,
        visitor_id String,
        session_id String,
        event_type LowCardinality(String) DEFAULT 'pageview',
        event_name String DEFAULT '',
        url_path String DEFAULT '',
        url_host String DEFAULT '',
        referrer_domain String DEFAULT '',
        referrer_url String DEFAULT '',
        utm_source String DEFAULT '',
        utm_medium String DEFAULT '',
        utm_campaign String DEFAULT '',
        utm_term String DEFAULT '',
        utm_content String DEFAULT '',
        device_type LowCardinality(String) DEFAULT '',
        browser LowCardinality(String) DEFAULT '',
        browser_version String DEFAULT '',
        os LowCardinality(String) DEFAULT '',
        os_version String DEFAULT '',
        screen_width UInt16 DEFAULT 0,
        screen_height UInt16 DEFAULT 0,
        ip_address String DEFAULT '',
        ip_country LowCardinality(String) DEFAULT '',
        ip_country_name String DEFAULT '',
        ip_continent LowCardinality(String) DEFAULT '',
        ip_continent_name String DEFAULT '',
        ip_region_code String DEFAULT '',
        ip_region_name String DEFAULT '',
        ip_city String DEFAULT '',
        ip_postal_code String DEFAULT '',
        ip_lat Float64 DEFAULT 0,
        ip_lon Float64 DEFAULT 0,
        ip_accuracy_radius UInt16 DEFAULT 0,
        ip_timezone String DEFAULT '',
        ip_asn UInt32 DEFAULT 0,
        ip_asn_org String DEFAULT '',
        ip_org String DEFAULT '',
        ip_is_datacenter UInt8 DEFAULT 0,
        ip_is_vpn UInt8 DEFAULT 0,
        ip_is_tor UInt8 DEFAULT 0,
        ip_is_bot UInt8 DEFAULT 0,
        ip_gdpr_anonymized UInt8 DEFAULT 0,
        duration_s UInt32 DEFAULT 0,
        properties String DEFAULT '{}',
        is_bounce UInt8 DEFAULT 1,
        timestamp DateTime DEFAULT now(),
        sign Int8 DEFAULT 1
      ) ENGINE = MergeTree()
      PARTITION BY toYYYYMM(timestamp)
      ORDER BY (site_id, timestamp, visitor_id)
      SETTINGS index_granularity = 8192
      """,
      """
      CREATE TABLE IF NOT EXISTS #{db}.ecommerce_events (
        site_id UInt64,
        visitor_id String,
        session_id String,
        order_id String,
        revenue Decimal(12, 2) DEFAULT 0,
        subtotal Decimal(12, 2) DEFAULT 0,
        tax Decimal(12, 2) DEFAULT 0,
        shipping Decimal(12, 2) DEFAULT 0,
        discount Decimal(12, 2) DEFAULT 0,
        currency LowCardinality(String) DEFAULT 'USD',
        items String DEFAULT '[]',
        timestamp DateTime DEFAULT now()
      ) ENGINE = MergeTree()
      PARTITION BY toYYYYMM(timestamp)
      ORDER BY (site_id, timestamp, order_id)
      SETTINGS index_granularity = 8192
      """,
      """
      CREATE MATERIALIZED VIEW IF NOT EXISTS #{db}.daily_stats
      ENGINE = SummingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date)
      AS SELECT
        site_id, toDate(timestamp) AS date,
        countIf(event_type = 'pageview') AS pageviews,
        uniqExact(visitor_id) AS visitors,
        uniqExact(session_id) AS sessions,
        sumIf(is_bounce, event_type = 'pageview') AS bounces,
        sumIf(duration_s, event_type = 'duration') AS total_duration
      FROM #{db}.events GROUP BY site_id, date
      """,
      """
      CREATE MATERIALIZED VIEW IF NOT EXISTS #{db}.source_stats
      ENGINE = SummingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, referrer_domain, utm_source, utm_medium)
      AS SELECT
        site_id, toDate(timestamp) AS date, referrer_domain, utm_source, utm_medium,
        countIf(event_type = 'pageview') AS pageviews,
        uniqExact(session_id) AS sessions
      FROM #{db}.events GROUP BY site_id, date, referrer_domain, utm_source, utm_medium
      """,
      """
      CREATE MATERIALIZED VIEW IF NOT EXISTS #{db}.country_stats
      ENGINE = SummingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, ip_country, ip_region_name, ip_city)
      AS SELECT
        site_id, toDate(timestamp) AS date, ip_country, ip_region_name, ip_city,
        countIf(event_type = 'pageview') AS pageviews,
        uniqExact(visitor_id) AS unique_visitors
      FROM #{db}.events GROUP BY site_id, date, ip_country, ip_region_name, ip_city
      """,
      """
      CREATE MATERIALIZED VIEW IF NOT EXISTS #{db}.device_stats
      ENGINE = SummingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, device_type, browser, os)
      AS SELECT
        site_id, toDate(timestamp) AS date, device_type, browser, os,
        countIf(event_type = 'pageview') AS pageviews,
        uniqExact(visitor_id) AS unique_visitors
      FROM #{db}.events GROUP BY site_id, date, device_type, browser, os
      """,
      """
      CREATE MATERIALIZED VIEW IF NOT EXISTS #{db}.network_stats
      ENGINE = SummingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, ip_asn, ip_asn_org)
      AS SELECT
        site_id, toDate(timestamp) AS date, ip_asn, ip_asn_org, ip_org,
        count() AS events,
        uniqExact(visitor_id) AS unique_visitors,
        sumIf(1, ip_is_datacenter = 1) AS datacenter_count,
        sumIf(1, ip_is_vpn = 1) AS vpn_count,
        sumIf(1, ip_is_tor = 1) AS tor_count,
        sumIf(1, ip_is_bot = 1) AS bot_count
      FROM #{db}.events GROUP BY site_id, date, ip_asn, ip_asn_org, ip_org
      """
    ]

    Enum.each(statements, fn sql ->
      case Req.post(admin_req, params: [query: String.trim(sql)]) do
        {:ok, %{status: 200}} ->
          :ok

        {:ok, %{status: s, body: b}} ->
          Logger.warning("[CH:init] #{s}: #{inspect(String.slice(to_string(b), 0, 200))}")

        {:error, r} ->
          Logger.warning("[CH:init] #{inspect(r)}")
      end
    end)

    Logger.info("[CH:init] Schema ensured for database #{db}")
  end

  defp build_req(url, user, pass, db) do
    Req.new(
      base_url: url,
      auth: {:basic, "#{user}:#{pass}"},
      params: [database: db],
      headers: [{"content-type", "application/x-www-form-urlencoded"}]
    )
    |> Req.merge(@default_opts)
  end

  defp write_req, do: Agent.get(__MODULE__, & &1.write)
  defp read_req, do: Agent.get(__MODULE__, & &1.read)

  @doc """
  Execute a SELECT query using the read-only credentials.
  Returns `{:ok, rows}` or `{:error, reason}`.
  """
  def query(sql, opts \\ []) do
    req = Req.merge(read_req(), params: [query: sql, default_format: "JSONEachRow"])

    case Req.get(req, opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_rows(body)}

      {:ok, %{status: s, body: b}} ->
        Logger.error("[CH:r] #{s}: #{inspect(b)}")
        {:error, b}

      {:error, r} ->
        Logger.error("[CH:r] #{inspect(r)}")
        {:error, r}
    end
  end

  @doc """
  Insert rows into a ClickHouse table using the write credentials.
  `rows` must be a non-empty list of maps.
  """
  def insert(table, rows) when is_list(rows) and rows != [] do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)

    req =
      Req.merge(write_req(),
        params: [
          query: "INSERT INTO #{sanitize_table(table)} FORMAT JSONEachRow",
          date_time_input_format: "best_effort"
        ],
        headers: [{"content-type", "text/plain"}]
      )

    case Req.post(req, body: body) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        Logger.error("[CH:w] #{s}: #{inspect(b)}")
        {:error, b}

      {:error, r} ->
        Logger.error("[CH:w] #{inspect(r)}")
        {:error, r}
    end
  end

  def insert(_table, []), do: :ok

  @doc """
  Escape a value for safe ClickHouse SQL interpolation.
  Use this for every user-supplied value in a query string.
  """
  def param(v) when is_integer(v), do: to_string(v)
  def param(v) when is_float(v), do: to_string(v)
  def param(nil), do: "NULL"

  def param(v) when is_binary(v) do
    e = v |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    "'#{e}'"
  end

  @allowed_tables ~w(events daily_stats source_stats country_stats device_stats network_stats ecommerce_events)
  defp sanitize_table(t) when t in @allowed_tables, do: t
  defp sanitize_table(t), do: raise(ArgumentError, "Unknown ClickHouse table: #{t}")

  defp parse_rows(""), do: []

  defp parse_rows(b) when is_binary(b),
    do: b |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp parse_rows(b) when is_list(b), do: b
end
