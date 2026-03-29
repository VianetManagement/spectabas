# Spectabas Performance & Efficiency Audit Prompt

You are performing a comprehensive performance audit of Spectabas, a multi-tenant web analytics SaaS platform. The system ingests events via a JavaScript tracker, buffers them in a GenServer, flushes to ClickHouse, and serves analytics dashboards via Phoenix LiveView. Performance matters at every layer — tracker impact on customer sites, ingest throughput, query latency, and dashboard responsiveness.

## Architecture Overview

- **Tracker** (`priv/static/s.js`) — ~8KB JavaScript loaded on customer sites
- **Collection** — POST to `/c/e`, validated by CollectPayload, enriched by Ingest, buffered by IngestBuffer
- **IngestBuffer** — GenServer batching events, flushes to ClickHouse every 500ms or 200 events
- **ClickHouse** — columnar analytics DB, MergeTree engine, partitioned by month
- **PostgreSQL** — users, sessions, visitors, sites (Ecto/Repo)
- **LiveView** — real-time dashboards with Chart.js, deferred loading pattern
- **GeoIP** — Geolix with DB-IP + MaxMind MMDB files in memory

---

## Audit Checklist

### A. Tracker Performance (Client-Side Impact)

1. **Script size and load impact**: Review `priv/static/s.js`. What is the minified/gzipped size? Could it be smaller? Are there unused features that could be lazy-loaded? Check: fingerprinting code (~60 lines), form abuse detection (~40 lines), RUM collection (~80 lines). Should these be deferred or conditional?

2. **Main thread blocking**: Does the tracker block the main thread during initialization? Review the synchronous `enhancedFingerprint()` call — it creates canvas elements, does WebGL lookups, and runs MurmurHash. How long does this take? Should it be deferred to a microtask or idle callback?

3. **Beacon efficiency**: Review `send()` function. It uses `sendBeacon` with `fetch` fallback. Is the 8KB payload limit appropriate? Are payloads being sent efficiently (single beacon vs multiple)?

4. **RUM polling overhead**: The RUM collector now polls at 0.5s, 1.5s, 3s, 5s, 8s intervals plus a load event listener. On a fast-loading page, how many unnecessary setTimeout callbacks fire? Should completed polls cancel remaining ones?

5. **Memory leaks**: Are PerformanceObserver instances properly cleaned up? Do event listeners accumulate on SPA navigation (pushState handler creates new listeners)?

### B. Event Ingestion Pipeline

6. **IngestBuffer throughput**: Review `lib/spectabas/events/ingest_buffer.ex`. At 500ms flush interval and 200 max batch, what's the theoretical max throughput? What happens under sustained 1000 events/sec? Profile the `do_flush` path — JSON encoding, HTTP POST to ClickHouse, PubSub broadcast.

7. **Ingest.process bottlenecks**: Review `lib/spectabas/events/ingest.ex`. Each event does: IP extraction, UA parsing, GeoIP lookup, visitor resolution (Postgres query), session resolution (Postgres + cache), URL parsing, UTM extraction, intent classification. Which of these is the bottleneck? Are there N+1 patterns?

8. **Session resolution performance**: Review `lib/spectabas/sessions.ex`. The SessionCache is an ETS table. On cache miss, it creates a new session (Postgres INSERT). Under high traffic, how many Postgres writes per second? Is the session cache sized appropriately?

9. **Visitor resolution Postgres queries**: Review `resolve_visitor` in ingest.ex. Each event may trigger: cookie lookup → fingerprint lookup → visitor creation. How many Postgres queries per event in the worst case? Can these be batched or cached?

10. **GeoIP lookup cost**: Geolix does an in-memory MMDB lookup per event. What's the cost? Is the MMDB file memory-mapped efficiently? Are lookups cached for repeated IPs?

11. **CollectPayload validation cost**: Ecto changeset validation runs on every event. Is this efficient for the volume? Could hot-path validation be done without Ecto?

### C. ClickHouse Query Performance

12. **Index utilization**: Review the MergeTree ORDER BY `(site_id, timestamp, visitor_id)`. Do all major queries filter by site_id first? Check queries that filter by: url_path, referrer_domain, visitor_intent, device_type, browser, ip_country — do they benefit from skip indexes?

13. **Bloom filter skip indexes**: The schema defines bloom filters on session_id, visitor_id, ip_country, browser, referrer_domain. Are these effective for the actual query patterns? Are there missing indexes?

14. **JSON property extraction cost**: RUM queries use `JSONExtractString(properties, 'key')` which parses JSON on every row. For high-volume sites, this could be expensive. Should RUM metrics be stored as dedicated columns instead of in the JSON properties blob?

15. **quantileIf aggregation cost**: RUM queries use `quantileIf(0.5)(expr, condition)` which evaluates the condition for every row. For large datasets, is this efficient? Would a materialized view or pre-aggregated table help?

16. **Full table scans**: Review all analytics queries for missing WHERE clauses or overly broad date ranges. Check: `total_events_today`, `overview_stats_public`, admin diagnostic queries. Do any skip the site_id filter?

17. **Subquery efficiency**: Several queries use subqueries (bounce rate per-session, attribution first/last touch, cohort retention). Are these efficient? Could they use ClickHouse-specific optimizations (arrayJoin, windowFunctions)?

18. **LIMIT clauses**: Do all list queries have LIMIT? Check: top_pages, top_sources, visitor_log, network_stats. What happens if a site has millions of unique pages?

### D. Dashboard LiveView Performance

19. **Mount data loading**: Review `site_live.ex` mount. It loads critical stats synchronously, then defers secondary data via `handle_info(:load_deferred)`. Is the critical path fast enough? What queries run on mount?

20. **N+1 on Your Sites index**: Review `index_live.ex`. It loops over all accessible sites and calls `Analytics.overview_stats` per site. With 10+ sites, this is 10+ ClickHouse queries on mount. Should this be a single batched query?

21. **LiveView payload size**: When the dashboard updates (time range change, segment filter), how much data is sent over the WebSocket? Are large tables causing excessive diffs? Check visitor_log (50 rows * 8 columns), timeseries data, map bubble data.

22. **PubSub broadcast overhead**: IngestBuffer broadcasts every flushed event batch to `site:{id}` topics. The realtime page subscribes. How many messages per second? Does this cause memory pressure on the LiveView process?

23. **Chart.js re-rendering**: When timeseries data updates, the entire dataset is pushed via `push_event`. Does Chart.js efficiently update, or does it destroy and recreate the canvas? Check the JS hook implementation.

24. **Deferred loading race conditions**: If a user changes the time range while deferred stats are still loading, do the old results overwrite the new request? Is there a request cancellation mechanism?

### E. Database Efficiency

25. **Postgres connection pool**: What's the pool size? Under high ingest load (visitor/session creation), is the pool exhausted? Check `config/runtime.exs` for pool_size setting.

26. **Postgres query patterns**: Review all Ecto queries for: missing indexes, sequential scans, unnecessary preloads, N+1 patterns in admin pages (user list, site list with stats).

27. **ClickHouse connection pooling**: Review `lib/spectabas/clickhouse.ex`. Is there connection reuse? Does each query open a new HTTP connection? Is keep-alive configured on Req?

28. **Dead letter queue**: When ClickHouse is down, events go to DeadLetter. Review `lib/spectabas/events/dead_letter.ex`. How is it stored? Is there a recovery mechanism? Could it grow unbounded?

### F. Caching Opportunities

29. **Site lookup caching**: Review `Sites.DomainCache`. Every event looks up a site by public key or domain. Is this cache effective? What's the TTL? Does it handle cache invalidation on site updates?

30. **Analytics query caching**: Are any ClickHouse query results cached? For the overview page (refreshes every 60s), could short-TTL caching reduce ClickHouse load?

31. **GeoIP result caching**: Same IP may generate hundreds of events. Is the GeoIP lookup result cached per IP? Could an LRU cache reduce MMDB lookups?

32. **Static asset caching**: Review cache headers on `/assets/v1.js` (now 1h), CSS/JS bundles, favicon. Are they optimal?

### G. Memory and Process Health

33. **BEAM memory usage**: Are there any processes that grow unbounded? Check: IngestBuffer state, SessionCache ETS table, DomainCache ETS table, PubSub subscriptions.

34. **Long-lived LiveView processes**: Dashboard LiveViews stay alive as long as the user's tab is open. Do they accumulate state? Is there periodic cleanup?

35. **Oban job efficiency**: Review all Oban workers (GeoIP refresh, cleanup jobs). Are they efficient? Do they hold large data in memory?

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Category**: Which section (A-G)
3. **Location**: File path and line number
4. **Description**: The performance issue
5. **Impact**: Estimated effect (latency, throughput, memory, CPU)
6. **Remediation**: Specific optimization with expected improvement

Conclude with a prioritized top 10 performance improvements ranked by impact.
