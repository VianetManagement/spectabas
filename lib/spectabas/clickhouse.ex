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
    # Set up Req structs immediately so queries can work as soon as CH is ready
    write_req = build_req(cfg[:url], cfg[:username], cfg[:password], cfg[:database])
    read_req = build_req(cfg[:url], cfg[:read_username], cfg[:read_password], cfg[:database])
    :persistent_term.put({__MODULE__, :write}, write_req)
    :persistent_term.put({__MODULE__, :read}, read_req)
    # Run schema init in background — don't block app startup
    Task.start(fn -> ensure_schema!(cfg) end)
    Agent.start_link(fn -> :ok end, name: __MODULE__)
  end

  defp ensure_schema!(cfg) do
    # Use default user (no password) to create database and tables
    admin_req =
      Req.new(
        base_url: cfg[:url],
        params: [user: "default", password: ""],
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )
      |> Req.merge(@default_opts)

    # Wait for ClickHouse to be ready (up to 30 seconds)
    connected = wait_for_clickhouse(admin_req, 15)

    unless connected do
      Logger.error(
        "[CH:init] Could not connect to ClickHouse after retries, skipping schema init"
      )

      :ok
    end

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
        ip_is_eu UInt8 DEFAULT 0,
        ip_gdpr_anonymized UInt8 DEFAULT 0,
        visitor_intent LowCardinality(String) DEFAULT '',
        user_agent String DEFAULT '',
        browser_fingerprint String DEFAULT '',
        click_id String DEFAULT '',
        click_id_type LowCardinality(String) DEFAULT '',
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
        refund_amount Decimal(12, 2) DEFAULT 0,
        import_source LowCardinality(String) DEFAULT '',
        currency LowCardinality(String) DEFAULT 'USD',
        items String DEFAULT '[]',
        timestamp DateTime DEFAULT now()
      ) ENGINE = MergeTree()
      PARTITION BY toYYYYMM(timestamp)
      ORDER BY (site_id, timestamp, order_id)
      SETTINGS index_granularity = 8192
      """,
      """
      CREATE TABLE IF NOT EXISTS #{db}.subscription_events (
        site_id UInt64,
        subscription_id String,
        customer_email String,
        visitor_id String DEFAULT '',
        plan_name String DEFAULT '',
        plan_interval LowCardinality(String) DEFAULT 'month',
        mrr_amount Decimal(12, 2) DEFAULT 0,
        currency LowCardinality(String) DEFAULT 'USD',
        status LowCardinality(String) DEFAULT 'active',
        event_type LowCardinality(String) DEFAULT 'snapshot',
        started_at DateTime DEFAULT now(),
        canceled_at DateTime DEFAULT toDateTime(0),
        current_period_end DateTime DEFAULT now(),
        snapshot_date Date DEFAULT today(),
        timestamp DateTime DEFAULT now()
      ) ENGINE = ReplacingMergeTree(timestamp)
      PARTITION BY toYYYYMM(snapshot_date)
      ORDER BY (site_id, snapshot_date, subscription_id)
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
      """,
      # Imported data rollup tables (for Matomo/external data imports)
      """
      CREATE TABLE IF NOT EXISTS #{db}.imported_daily_stats (
        site_id UInt64,
        date Date,
        pageviews UInt64 DEFAULT 0,
        visitors UInt64 DEFAULT 0,
        sessions UInt64 DEFAULT 0,
        bounces UInt64 DEFAULT 0,
        total_duration UInt64 DEFAULT 0
      ) ENGINE = ReplacingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date)
      """,
      """
      CREATE TABLE IF NOT EXISTS #{db}.imported_pages (
        site_id UInt64,
        date Date,
        url_path String,
        pageviews UInt64 DEFAULT 0,
        visitors UInt64 DEFAULT 0
      ) ENGINE = ReplacingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, url_path)
      """,
      """
      CREATE TABLE IF NOT EXISTS #{db}.imported_sources (
        site_id UInt64,
        date Date,
        referrer_domain String DEFAULT '',
        utm_source String DEFAULT '',
        utm_medium String DEFAULT '',
        pageviews UInt64 DEFAULT 0,
        sessions UInt64 DEFAULT 0,
        visitors UInt64 DEFAULT 0
      ) ENGINE = ReplacingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, referrer_domain, utm_source, utm_medium)
      """,
      """
      CREATE TABLE IF NOT EXISTS #{db}.imported_countries (
        site_id UInt64,
        date Date,
        ip_country LowCardinality(String) DEFAULT '',
        ip_country_name String DEFAULT '',
        pageviews UInt64 DEFAULT 0,
        visitors UInt64 DEFAULT 0
      ) ENGINE = ReplacingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, ip_country)
      """,
      """
      CREATE TABLE IF NOT EXISTS #{db}.imported_devices (
        site_id UInt64,
        date Date,
        device_type LowCardinality(String) DEFAULT '',
        browser LowCardinality(String) DEFAULT '',
        os LowCardinality(String) DEFAULT '',
        pageviews UInt64 DEFAULT 0,
        visitors UInt64 DEFAULT 0
      ) ENGINE = ReplacingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, device_type, browser, os)
      """,
      # Ad spend data from connected ad platforms
      """
      CREATE TABLE IF NOT EXISTS #{db}.ad_spend (
        site_id UInt64,
        date Date,
        platform LowCardinality(String),
        account_id String,
        campaign_id String,
        campaign_name String DEFAULT '',
        spend Decimal(12, 2) DEFAULT 0,
        clicks UInt64 DEFAULT 0,
        impressions UInt64 DEFAULT 0,
        currency LowCardinality(String) DEFAULT 'USD',
        synced_at DateTime DEFAULT now()
      ) ENGINE = ReplacingMergeTree(synced_at)
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, platform, campaign_id)
      """,
      # Users and grants
      "CREATE USER IF NOT EXISTS #{cfg[:username]} IDENTIFIED WITH plaintext_password BY '#{cfg[:password]}'",
      "CREATE USER IF NOT EXISTS #{cfg[:read_username]} IDENTIFIED WITH plaintext_password BY '#{cfg[:read_password]}'",
      "GRANT INSERT, SELECT, ALTER, OPTIMIZE ON #{db}.* TO #{cfg[:username]}",
      "GRANT SELECT ON #{db}.* TO #{cfg[:read_username]}",
      "ALTER TABLE #{db}.events ADD COLUMN IF NOT EXISTS ip_is_eu UInt8 DEFAULT 0 AFTER ip_is_bot",
      "ALTER TABLE #{db}.events ADD COLUMN IF NOT EXISTS visitor_intent String DEFAULT '' AFTER ip_gdpr_anonymized",
      "ALTER TABLE #{db}.events ADD COLUMN IF NOT EXISTS user_agent String DEFAULT '' AFTER visitor_intent",
      "ALTER TABLE #{db}.events ADD COLUMN IF NOT EXISTS browser_fingerprint String DEFAULT '' AFTER user_agent",
      "ALTER TABLE #{db}.events ADD COLUMN IF NOT EXISTS click_id String DEFAULT '' AFTER browser_fingerprint",
      "ALTER TABLE #{db}.events ADD COLUMN IF NOT EXISTS click_id_type LowCardinality(String) DEFAULT '' AFTER click_id",
      # Data retention: delete events older than 2 years
      "ALTER TABLE #{db}.events MODIFY TTL timestamp + INTERVAL 2 YEAR",
      # Skip indexes for common query patterns
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_session session_id TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_visitor visitor_id TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_country ip_country TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_browser browser TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_referrer referrer_domain TYPE bloom_filter GRANULARITY 4",
      """
      CREATE TABLE IF NOT EXISTS #{db}.search_console (
        site_id UInt64,
        date Date,
        query String,
        page String,
        country LowCardinality(String) DEFAULT '',
        device LowCardinality(String) DEFAULT '',
        source LowCardinality(String) DEFAULT 'google',
        clicks UInt32 DEFAULT 0,
        impressions UInt32 DEFAULT 0,
        ctr Float32 DEFAULT 0,
        position Float32 DEFAULT 0,
        synced_at DateTime DEFAULT now()
      ) ENGINE = ReplacingMergeTree(synced_at)
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, query, page, country, device, source)
      SETTINGS index_granularity = 8192
      """,
      # Daily pre-aggregated rollup for fast 7/30/90-day timeseries charts.
      # Uses AggregatingMergeTree with uniqExactState for exact cross-merge-safe visitor counts.
      # Populated by Spectabas.Workers.DailyRollup (daily cron + historical backfill).
      """
      CREATE TABLE IF NOT EXISTS #{db}.daily_rollup (
        site_id UInt64,
        date Date,
        pv_state AggregateFunction(countIf, UInt8, UInt8),
        vis_state AggregateFunction(uniqExactIf, String, UInt8),
        sess_state AggregateFunction(uniqExactIf, String, UInt8)
      ) ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date)
      SETTINGS index_granularity = 8192
      """,
      # Per-URL rollup for top_pages / (partial) entry_pages queries.
      """
      CREATE TABLE IF NOT EXISTS #{db}.daily_page_rollup (
        site_id UInt64,
        date Date,
        url_path String,
        pv_state AggregateFunction(countIf, UInt8, UInt8),
        vis_state AggregateFunction(uniqExactIf, String, UInt8)
      ) ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, url_path)
      SETTINGS index_granularity = 8192
      """,
      # Per-source rollup for top_sources queries.
      """
      CREATE TABLE IF NOT EXISTS #{db}.daily_source_rollup (
        site_id UInt64,
        date Date,
        referrer_domain String,
        pv_state AggregateFunction(countIf, UInt8, UInt8),
        sess_state AggregateFunction(uniqExactIf, String, UInt8)
      ) ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, referrer_domain)
      SETTINGS index_granularity = 8192
      """,
      # Per-geo rollup for top_regions / visitor_locations / timezone_distribution queries.
      """
      CREATE TABLE IF NOT EXISTS #{db}.daily_geo_rollup (
        site_id UInt64,
        date Date,
        ip_country LowCardinality(String),
        ip_region_name String,
        ip_city String,
        ip_lat Float64,
        ip_lon Float64,
        ip_timezone LowCardinality(String),
        pv_state AggregateFunction(countIf, UInt8, UInt8),
        vis_state AggregateFunction(uniqExactIf, String, UInt8)
      ) ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, ip_country, ip_region_name, ip_city)
      SETTINGS index_granularity = 8192
      """,
      # Per-device rollup for top_browsers / top_os queries.
      """
      CREATE TABLE IF NOT EXISTS #{db}.daily_device_rollup (
        site_id UInt64,
        date Date,
        device_type LowCardinality(String),
        browser LowCardinality(String),
        os LowCardinality(String),
        pv_state AggregateFunction(countIf, UInt8, UInt8),
        vis_state AggregateFunction(uniqExactIf, String, UInt8)
      ) ENGINE = AggregatingMergeTree()
      PARTITION BY toYYYYMM(date)
      ORDER BY (site_id, date, device_type, browser, os)
      SETTINGS index_granularity = 8192
      """,
      # Schema migrations — add columns that may not exist on older tables
      "ALTER TABLE #{db}.ecommerce_events ADD COLUMN IF NOT EXISTS refund_amount Decimal(12, 2) DEFAULT 0",
      "ALTER TABLE #{db}.ecommerce_events ADD COLUMN IF NOT EXISTS import_source LowCardinality(String) DEFAULT ''",
      # Subscription events table (idempotent — CREATE IF NOT EXISTS above)
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_event_type event_type TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_event_name event_name TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_url_path url_path TYPE bloom_filter GRANULARITY 4",
      "ALTER TABLE #{db}.events ADD INDEX IF NOT EXISTS idx_click_id click_id TYPE bloom_filter GRANULARITY 4"
    ]

    if connected do
      results =
        Enum.map(statements, fn sql ->
          trimmed = String.trim(sql)
          # Extract a short name for logging
          name = trimmed |> String.split("\n") |> hd() |> String.slice(0, 60)

          case Req.post(admin_req, params: [query: trimmed], body: "") do
            {:ok, %{status: 200}} ->
              Logger.info("[CH:init] OK: #{name}")
              :ok

            {:ok, %{status: s, body: b}} ->
              Logger.error(
                "[CH:init] FAILED (#{s}): #{name} — #{String.slice(to_string(b), 0, 300)}"
              )

              :error

            {:error, r} ->
              Logger.error("[CH:init] FAILED: #{name} — #{inspect(r)}")
              :error
          end
        end)

      errors = Enum.count(results, &(&1 == :error))

      Logger.info(
        "[CH:init] Schema ensured for database #{db} (#{length(results) - errors}/#{length(results)} OK)"
      )
    end
  end

  defp wait_for_clickhouse(req, retries) when retries > 0 do
    case Req.post(req, params: [query: "SELECT 1"], body: "") do
      {:ok, %{status: 200}} ->
        Logger.info("[CH:init] Connected to ClickHouse")
        true

      {:ok, %{status: s, body: b}} ->
        Logger.warning(
          "[CH:init] Not ready (#{s}): #{String.slice(to_string(b), 0, 100)}, retrying..."
        )

        Process.sleep(2_000)
        wait_for_clickhouse(req, retries - 1)

      {:error, r} ->
        Logger.warning("[CH:init] Not ready: #{inspect(r)}, retrying...")
        Process.sleep(2_000)
        wait_for_clickhouse(req, retries - 1)
    end
  end

  defp wait_for_clickhouse(_req, 0) do
    false
  end

  defp build_req(url, user, pass, db) do
    Req.new(
      base_url: url,
      params: [database: db, user: user, password: pass],
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      finch: Spectabas.ClickHouseFinch
    )
    |> Req.merge(@default_opts)
  end

  defp write_req, do: :persistent_term.get({__MODULE__, :write})
  defp read_req, do: :persistent_term.get({__MODULE__, :read})

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
        Logger.error("[CH:r] #{s}: #{inspect(b)} — query: #{String.slice(sql, 0, 300)}")
        {:error, b}

      {:error, r} ->
        Logger.error("[CH:r] #{inspect(r)} — query: #{String.slice(sql, 0, 300)}")
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

  @doc "Execute SQL as admin/default user (for DDL: CREATE TABLE, ALTER TABLE ADD COLUMN, etc.)"
  def execute_admin(sql) do
    cfg = Application.get_env(:spectabas, __MODULE__)

    admin_req =
      Req.new(
        base_url: cfg[:url],
        params: [user: "default", password: ""],
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      )
      |> Req.merge(@default_opts)

    req = Req.merge(admin_req, params: [query: sql])

    case Req.post(req, body: "") do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        Logger.error("[CH:admin] #{s}: #{inspect(b)}")
        {:error, b}

      {:error, e} ->
        Logger.error("[CH:admin] #{inspect(e)}")
        {:error, e}
    end
  end

  def execute(sql) do
    req = Req.merge(write_req(), params: [query: sql])

    case Req.post(req, body: "") do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: s, body: b}} ->
        Logger.error("[CH:exec] #{s}: #{inspect(b)}")
        {:error, b}

      {:error, r} ->
        Logger.error("[CH:exec] #{inspect(r)}")
        {:error, r}
    end
  end

  @doc "Returns the configured ClickHouse database name."
  def database do
    cfg = Application.get_env(:spectabas, __MODULE__, [])
    cfg[:database] || "spectabas"
  end

  @doc """
  Escape a value for safe ClickHouse SQL interpolation.
  Use this for every user-supplied value in a query string.
  """
  def param(v) when is_integer(v), do: to_string(v)
  def param(v) when is_float(v), do: to_string(v)
  def param(nil), do: "NULL"

  def param(v) when is_binary(v) do
    e =
      v
      |> String.replace("\0", "")
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'#{e}'"
  end

  @allowed_tables ~w(events daily_stats daily_rollup daily_page_rollup daily_source_rollup daily_geo_rollup daily_device_rollup source_stats country_stats device_stats network_stats ecommerce_events subscription_events search_console imported_daily_stats imported_pages imported_sources imported_countries imported_devices ad_spend)
  defp sanitize_table(t) when t in @allowed_tables, do: t
  defp sanitize_table(t), do: raise(ArgumentError, "Unknown ClickHouse table: #{t}")

  defp parse_rows(""), do: []

  defp parse_rows(b) when is_binary(b) do
    b
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      # ClickHouse JSONEachRow can contain nan/inf which are not valid JSON.
      # Replace them with null before parsing.
      line
      |> String.replace(~r/:nan([,}])/, ":null\\1")
      |> String.replace(~r/:-?inf([,}])/, ":null\\1")
      |> Jason.decode!()
    end)
  end

  defp parse_rows(b) when is_list(b), do: b
end
