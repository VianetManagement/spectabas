# Spectabas Error Handling & Resilience Audit Prompt

You are auditing how Spectabas handles failures, degraded states, and edge cases. Analytics platforms must be resilient — if ClickHouse is down for an hour, events shouldn't be permanently lost. If Postgres is slow, the dashboard should degrade gracefully, not crash. Users should always see helpful error states, never blank screens or cryptic errors.

---

## Audit Checklist

### A. ClickHouse Failures

1. **ClickHouse completely down**: Walk through what happens when ClickHouse is unreachable:
   - Does the app start? Review `ensure_schema!` in `lib/spectabas/clickhouse.ex` — it retries 15 times then skips.
   - Do events still get accepted? The collect endpoint should still return 204.
   - Where do events go? Review IngestBuffer → DeadLetter flow.
   - What does the dashboard show? Do queries return errors or empty data? Does the LiveView crash?
   - What does `/health` return?

2. **ClickHouse slow responses**: What happens when ClickHouse queries take 30+ seconds?
   - Are there timeouts on the HTTP client (Req)? Check `@default_opts` in clickhouse.ex.
   - Do slow queries block the LiveView process? Is there a Task wrapper?
   - Can one slow query on the dashboard page block the entire mount?

3. **ClickHouse partial failure**: What if writes succeed but reads fail (e.g., reader user password changed)?
   - Does IngestBuffer flush succeed while dashboard queries fail?
   - Is the error message useful or cryptic?

4. **DeadLetter recovery**: Review `lib/spectabas/events/dead_letter.ex`.
   - How are dead-lettered events stored? In memory? On disk? In Postgres?
   - Is there a recovery mechanism to replay dead-lettered events when ClickHouse comes back?
   - Can the dead letter queue grow unbounded and OOM the BEAM?
   - Is there monitoring/alerting on dead letter size?

5. **ClickHouse schema drift**: What happens if the ClickHouse events table schema doesn't match what the app expects (e.g., missing column after a deploy)?
   - Does `ensure_schema!` handle ALTER TABLE for new columns?
   - What error does a write produce if a column is missing?

### B. PostgreSQL Failures

6. **Postgres connection pool exhaustion**: Under high ingest load, each event may create/update visitors and sessions.
   - What's the pool size? Is it configurable?
   - What happens when all connections are checked out? Does the event pipeline stall?
   - Are there queue timeouts?

7. **Postgres down during event ingest**: The collect endpoint calls `resolve_visitor` and `resolve_session` which query Postgres.
   - Does a Postgres failure crash the event pipeline?
   - Is the Postgres failure caught gracefully in the `try/rescue` block in CollectController?
   - Are events lost or queued?

8. **Postgres slow queries**: Visitor/session lookup queries under high load.
   - Are there indexes on: visitors.site_id + fingerprint, sessions.site_id + visitor_id, sessions.site_id + session_id?
   - What's the worst-case query plan?

9. **Migration failures**: What happens if a migration fails mid-deploy?
   - Does the start script (`rel/overlays/bin/start`) handle migration errors?
   - Can the app start with a partially migrated database?

### C. External Service Failures

10. **GeoIP database corruption/missing**: What happens if MMDB files are missing or corrupt?
    - Does the app start without GeoIP?
    - Are events still processed (just without geo data)?
    - Is the error logged clearly?

11. **Resend email service down**: What happens when sending magic link or invitation emails fails?
    - Is there retry logic?
    - Does the user see a helpful error message?
    - Are failed emails logged?

12. **Render custom domain registration failure**: When auto-registering analytics subdomains.
    - Does a Render API failure prevent site creation?
    - Is there manual fallback documented?

13. **MaxMind download failure**: Runtime download of GeoLite2 database.
    - Does the app function without MaxMind (only DB-IP)?
    - Is the failure logged and retried?

### D. Dashboard Error States

14. **Empty data**: For every dashboard page, what shows when there's zero data?
    - Is there a helpful empty state message?
    - Does the chart render empty or crash?
    - Do tables show "No data" or just a blank white box?

15. **Partial data failure**: What if one query succeeds but another fails on the overview page?
    - Are stat cards independent? Does one failing query blank out all cards?
    - Does the timeseries chart handle a query error gracefully?
    - Do deferred stats (top pages, sources, etc.) show loading states?

16. **ClickHouse timeout on dashboard**: If a ClickHouse query times out mid-page-load:
    - Does the LiveView crash and reconnect?
    - Does the user see a flash error?
    - Is the error retryable (pull-to-refresh, "Retry" button)?

17. **Concurrent time range changes**: User rapidly clicks Today → 24h → 7d → 30d.
    - Do all four queries fire? Do results arrive out of order?
    - Does the display flicker between results?
    - Is there request debouncing or cancellation?

### E. Event Pipeline Edge Cases

18. **Malformed events**: What happens with:
    - Missing required fields (no URL, no visitor_id)
    - Extremely long URLs (2049+ chars)
    - Unicode/emoji in page paths
    - Null bytes in strings
    - Nested JSON in properties
    - Integer values in properties (should be strings)
    - NaN/Infinity in screen dimensions

19. **Clock skew**: If the server clock drifts, event timestamps are wrong.
    - Are there any dependencies on monotonic time vs wall clock?
    - Does session timeout logic handle clock jumps?

20. **Extremely high cardinality**: A site with 1 million unique URL paths (e.g., user-generated URLs).
    - Do `GROUP BY url_path` queries explode in memory?
    - Are there LIMIT clauses on all path-aggregation queries?
    - Does the Pages table paginate or load all results?

21. **Race conditions in visitor creation**: Two concurrent events for the same new visitor.
    - Does `resolve_visitor` handle the race where both try to INSERT?
    - Is there a unique constraint on visitor_id + site_id?
    - Could this create duplicate visitor records?

### F. Deployment & Startup

22. **Zero-downtime deploys**: Review the Render deployment process.
    - Is there a health check that Render uses before routing traffic?
    - During deploy, do in-flight events get lost?
    - Does the IngestBuffer drain before shutdown?

23. **Startup order dependencies**: The app depends on Postgres, ClickHouse, Geolix, UAInspector.
    - What happens if ClickHouse isn't ready at startup? (Review ensure_schema! retry logic)
    - What if the MMDB files haven't been downloaded yet?
    - Is there a startup health gate?

24. **OTP supervisor restart strategy**: If IngestBuffer crashes:
    - Does the supervisor restart it?
    - Are buffered events lost on crash?
    - Is there a crash loop detection?

### G. Observability

25. **Logging adequacy**: Are errors logged with enough context to debug?
    - Do ClickHouse query errors include the SQL?
    - Do ingest errors include the site_id and event type?
    - Are Postgres errors logged with the query?

26. **Metrics/monitoring**: Is there any application-level metrics collection?
    - Event ingest rate
    - ClickHouse query latency
    - Buffer size over time
    - Dead letter queue size
    - Error rates by type

27. **Alerting**: Are there any automated alerts for:
    - ClickHouse down
    - Dead letter queue growing
    - Ingest rate drop (indicates tracker issue)
    - Error rate spike

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Category**: Which section (A-G)
3. **Failure scenario**: What triggers this issue
4. **Current behavior**: What happens now
5. **Expected behavior**: What should happen
6. **Location**: File path and relevant code
7. **Remediation**: Specific fix

Conclude with: a resilience scorecard (A-F grade per category) and the top 10 improvements ranked by risk reduction.
