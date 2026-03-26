-- Spectabas ClickHouse Schema
-- Run this against a fresh ClickHouse instance

CREATE DATABASE IF NOT EXISTS spectabas;

-- Users (change passwords before production!)
CREATE USER IF NOT EXISTS spectabas_writer IDENTIFIED WITH sha256_password BY 'CHANGE_ME_WRITER';
CREATE USER IF NOT EXISTS spectabas_reader IDENTIFIED WITH sha256_password BY 'CHANGE_ME_READER';

-- Main events table
CREATE TABLE IF NOT EXISTS spectabas.events
(
    event_id          UUID DEFAULT generateUUIDv4(),
    site_id           UInt64,
    visitor_id        String,
    session_id        String,
    event_type        LowCardinality(String) DEFAULT 'pageview',
    event_name        String DEFAULT '',
    url_path          String DEFAULT '',
    url_host          String DEFAULT '',
    referrer_domain   String DEFAULT '',
    referrer_url      String DEFAULT '',

    -- UTM parameters
    utm_source        String DEFAULT '',
    utm_medium        String DEFAULT '',
    utm_campaign      String DEFAULT '',
    utm_term          String DEFAULT '',
    utm_content       String DEFAULT '',

    -- Device info
    device_type       LowCardinality(String) DEFAULT '',
    browser           LowCardinality(String) DEFAULT '',
    browser_version   String DEFAULT '',
    os                LowCardinality(String) DEFAULT '',
    os_version        String DEFAULT '',
    screen_width      UInt16 DEFAULT 0,
    screen_height     UInt16 DEFAULT 0,

    -- IP enrichment
    ip_address        String DEFAULT '',
    ip_country        LowCardinality(String) DEFAULT '',
    ip_country_name   String DEFAULT '',
    ip_continent      LowCardinality(String) DEFAULT '',
    ip_continent_name String DEFAULT '',
    ip_region_code    String DEFAULT '',
    ip_region_name    String DEFAULT '',
    ip_city           String DEFAULT '',
    ip_postal_code    String DEFAULT '',
    ip_lat            Float64 DEFAULT 0,
    ip_lon            Float64 DEFAULT 0,
    ip_accuracy_radius UInt16 DEFAULT 0,
    ip_timezone       String DEFAULT '',
    ip_asn            UInt32 DEFAULT 0,
    ip_asn_org        String DEFAULT '',
    ip_org            String DEFAULT '',
    ip_is_datacenter  UInt8 DEFAULT 0,
    ip_is_vpn         UInt8 DEFAULT 0,
    ip_is_tor         UInt8 DEFAULT 0,
    ip_is_bot         UInt8 DEFAULT 0,
    ip_gdpr_anonymized UInt8 DEFAULT 0,

    -- Duration and properties
    duration_s        UInt32 DEFAULT 0,
    properties        String DEFAULT '{}',

    -- Bounce
    is_bounce         UInt8 DEFAULT 1,

    -- Timestamp
    timestamp         DateTime DEFAULT now(),

    -- Sign for CollapsingMergeTree (optional, for updates)
    sign              Int8 DEFAULT 1
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (site_id, timestamp, visitor_id)
TTL timestamp + INTERVAL 365 DAY DELETE,
    timestamp + INTERVAL 90 DAY SET ip_address = '' WHERE ip_gdpr_anonymized = 1
SETTINGS index_granularity = 8192;

-- Ecommerce events table
CREATE TABLE IF NOT EXISTS spectabas.ecommerce_events
(
    site_id       UInt64,
    visitor_id    String,
    session_id    String,
    order_id      String,
    revenue       Decimal(12, 2) DEFAULT 0,
    subtotal      Decimal(12, 2) DEFAULT 0,
    tax           Decimal(12, 2) DEFAULT 0,
    shipping      Decimal(12, 2) DEFAULT 0,
    discount      Decimal(12, 2) DEFAULT 0,
    currency      LowCardinality(String) DEFAULT 'USD',
    items         String DEFAULT '[]',
    timestamp     DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (site_id, timestamp, order_id)
SETTINGS index_granularity = 8192;

-- Materialized view: daily stats
CREATE MATERIALIZED VIEW IF NOT EXISTS spectabas.daily_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (site_id, date)
AS SELECT
    site_id,
    toDate(timestamp) AS date,
    countIf(event_type = 'pageview') AS pageviews,
    uniqExact(visitor_id) AS unique_visitors,
    uniqExact(session_id) AS sessions,
    sumIf(is_bounce, event_type = 'pageview') AS bounces,
    sumIf(duration_s, event_type = 'duration') AS total_duration
FROM spectabas.events
GROUP BY site_id, date;

-- Materialized view: source stats
CREATE MATERIALIZED VIEW IF NOT EXISTS spectabas.source_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (site_id, date, referrer_domain, utm_source, utm_medium)
AS SELECT
    site_id,
    toDate(timestamp) AS date,
    referrer_domain,
    utm_source,
    utm_medium,
    countIf(event_type = 'pageview') AS pageviews,
    uniqExact(session_id) AS sessions
FROM spectabas.events
GROUP BY site_id, date, referrer_domain, utm_source, utm_medium;

-- Materialized view: country stats
CREATE MATERIALIZED VIEW IF NOT EXISTS spectabas.country_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (site_id, date, ip_country, ip_region_name, ip_city)
AS SELECT
    site_id,
    toDate(timestamp) AS date,
    ip_country,
    ip_region_name,
    ip_city,
    countIf(event_type = 'pageview') AS pageviews,
    uniqExact(visitor_id) AS unique_visitors
FROM spectabas.events
GROUP BY site_id, date, ip_country, ip_region_name, ip_city;

-- Materialized view: device stats
CREATE MATERIALIZED VIEW IF NOT EXISTS spectabas.device_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (site_id, date, device_type, browser, os)
AS SELECT
    site_id,
    toDate(timestamp) AS date,
    device_type,
    browser,
    os,
    countIf(event_type = 'pageview') AS pageviews,
    uniqExact(visitor_id) AS unique_visitors
FROM spectabas.events
GROUP BY site_id, date, device_type, browser, os;

-- Materialized view: network stats
CREATE MATERIALIZED VIEW IF NOT EXISTS spectabas.network_stats
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (site_id, date, ip_asn, ip_asn_org)
AS SELECT
    site_id,
    toDate(timestamp) AS date,
    ip_asn,
    ip_asn_org,
    ip_org,
    count() AS events,
    uniqExact(visitor_id) AS unique_visitors,
    sumIf(1, ip_is_datacenter = 1) AS datacenter_count,
    sumIf(1, ip_is_vpn = 1) AS vpn_count,
    sumIf(1, ip_is_tor = 1) AS tor_count,
    sumIf(1, ip_is_bot = 1) AS bot_count
FROM spectabas.events
GROUP BY site_id, date, ip_asn, ip_asn_org, ip_org;

-- Grants
GRANT INSERT ON spectabas.events TO spectabas_writer;
GRANT INSERT ON spectabas.ecommerce_events TO spectabas_writer;
GRANT SELECT ON spectabas.* TO spectabas_reader;
