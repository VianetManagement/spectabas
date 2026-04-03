# Spectabas Security Audit Prompt (v4.8.0)

You are performing a comprehensive security audit of Spectabas, a multi-tenant web analytics SaaS platform built with Elixir/Phoenix. The platform collects visitor behavior data via a JavaScript tracker, stores events in ClickHouse, and serves analytics dashboards via Phoenix LiveView.

## System Architecture

- **Elixir 1.17 / Phoenix 1.8** with LiveView, scope-based auth
- **PostgreSQL** — users, sessions, visitors, sites, API keys, audit logs, ad integrations, goals, campaigns, segments, email reports
- **ClickHouse** — analytics events (pageviews, custom events, ecommerce, RUM, CWV), ad spend data (ReplacingMergeTree), imported rollup tables
- **Render** — Docker-based deployment (non-root user), auto-deploy on push to main
- **Resend** — transactional email delivery
- **Geolix** — IP geolocation (DB-IP + MaxMind GeoLite2 MMDB files)
- **tzdata** — timezone database for site-local date boundaries
- **wax_** — WebAuthn/FIDO2 passkey 2FA
- **Oban** — background job queue (ad sync, email reports, spam detection, GeoIP updates)

## Attack Surface

### 1. Event Collection Endpoints (public, unauthenticated)
- `POST /c/e` — event collection (pageview, custom, duration, ecommerce_order, ecommerce_item, xdtoken)
- `GET /c/p` — noscript pixel tracking
- `POST /c/i` — client-side visitor identification (email, user_id traits)
- `POST /c/x` — cross-domain token exchange
- `POST /c/o` — opt-out cookie setter
- Rate-limited via Hammer (300/min per IP for collect, 10/min for login)
- Validates payload via Ecto embedded schema (CollectPayload)
- Origin/Referer validation against site domain + subdomains
- Resolves site by public key or domain

### 2. JavaScript Tracker (`/assets/v1.js`)
- Served from customer analytics subdomains (e.g., `b.example.com`)
- `data-proxy` attribute enables reverse proxy mode through main domain
- Sends beacons with visitor ID, session ID, page URL, referrer, screen dimensions
- GDPR mode: cookie-based (off) or fingerprint-based (on)
- Cross-domain token exchange via `/c/x`
- Client-side bot detection (`_bot`, `_hi`)
- Browser fingerprinting: canvas, WebGL, navigator signals, MurmurHash3
- RUM collection: Performance API navigation timing, PerformanceObserver for CWV
- Click ID capture: gclid, msclkid, fbclid from URL → sessionStorage → beacon
- Public JavaScript API: `Spectabas.track()`, `Spectabas.identify()`, `Spectabas.optOut()`, `Spectabas.ecommerce.addOrder()`, `Spectabas.ecommerce.addItem()`

### 3. REST API (`/api/v1/*`, token-authenticated)
- Bearer token authentication via API keys with granular scopes
- Scopes: `read:stats`, `read:visitors`, `write:events`, `write:identify`, `admin:sites`
- Tokens can be restricted to specific site IDs
- Optional expiry dates on tokens
- All API calls logged (request/response bodies, 30-day retention)
- Endpoints: stats, pages, sources, countries, devices, realtime, identify, ecommerce transactions

### 4. Dashboard (LiveView, authenticated)
- 36 analytics pages across 7 sidebar categories
- All ClickHouse queries use `ClickHouse.param/1` for value interpolation
- Segment filters build WHERE clauses from user input (`analytics/segment.ex`)
- Visitor profiles show IP addresses and cross-reference other visitors by IP
- Admin pages: user management, site management, ingest diagnostics, API logs, spam filter, changelog
- Docs page uses custom markdown renderer with `raw/1` output

### 5. Authentication & Authorization
- Phoenix 1.8 scope-based auth (current_scope, not current_user)
- Magic link login (email token)
- Password authentication (bcrypt)
- Optional TOTP 2FA (NimbleTOTP)
- Optional WebAuthn/passkey 2FA (wax_ library)
- Role-based access: superadmin, admin, analyst, viewer
- Granular per-site access for analyst/viewer roles
- Admin can force 2FA per user
- Session tokens in cookies

### 6. Ad Platform Integrations (OAuth2)
- Google Ads, Bing Ads, Meta/Facebook Ads connections per site
- OAuth2 tokens encrypted at rest via AES-256-GCM (Vault module, key derived from SECRET_KEY_BASE)
- Platform credentials (client_id, client_secret, developer_token) stored as encrypted JSON blob in sites.ad_credentials_encrypted
- Account picker flow stores pending tokens in session during OAuth
- Oban worker syncs spend data every 6 hours

### 7. Site-Configurable Intent Classification
- `sites.intent_config` stores path pattern lists (buying, engaging, support paths)
- Configurable from Site Settings by any user with site access
- Paths are substring-matched against visitor URL paths during ingest
- No regex or code execution — pure `String.contains?/2`

### 8. Email Reports
- Per-user per-site subscriptions (daily/weekly/monthly)
- Unsubscribe via signed Phoenix.Token (30-day validity)
- HTML emails with analytics data
- Oban dispatcher every 15 minutes

### 9. Ecommerce
- Transaction API: `POST /api/v1/sites/:site_id/ecommerce/transactions`
- Accepts: order_id, revenue, items, visitor_id, email
- Email association links orders to visitor profiles
- Stored in ClickHouse ecommerce_events table

### 10. Infrastructure
- Docker on Render (non-root runtime user)
- ClickHouse with separate reader/writer users (writer has INSERT, SELECT, ALTER, OPTIMIZE)
- Health endpoints: `/health` (public, returns ok/degraded only), `/health/*` diagnostic endpoints (admin-only)
- Token-protected utility endpoints: `/matomo-import-test`, `/send-setup-emails`, `/click-id-diag`
- GeoIP databases refreshed via Oban cron (1st and 15th of month)

---

## Audit Checklist — Review EVERY item below

### A. SQL/Query Injection

1. **ClickHouse `param/1` escaping**: Review `lib/spectabas/clickhouse.ex` `param/1`. Does it properly escape strings (single quotes, backslashes, null bytes)? Check all value types.

2. **Segment filter injection**: Review `lib/spectabas/analytics/segment.ex` `to_sql/1`. User-supplied field names, operators, and values build WHERE clauses. Verify:
   - Field names validated against `@allowed_fields` whitelist
   - Operators restricted to known set
   - Values parameterized via `ClickHouse.param/1`
   - No raw interpolation of user input

3. **ClickHouse `execute/1` callers**: This function runs SQL with write credentials. Audit every caller — can any user input reach it unsanitized? Check: ad spend optimize, schema setup, backfill-geo, data cleanup workers.

4. **API access log LIKE query**: `admin/api_logs_live.ex` uses `like(l.path, ^"%#{path}%")` for filtering. Is this Ecto-parameterized or raw interpolation?

5. **Spam filter domain storage**: Domains from admin input stored in DB and used in ClickHouse query exclusions. Verify parameterization of spam domain list in analytics queries.

6. **ClickHouse insert path**: `ClickHouse.insert/2` sends rows as JSON bodies. Verify table name sanitization via `sanitize_table/1` whitelist. Verify no SQL injection via JSON field values.

### B. Authentication & Session Security

7. **Magic link token**: Review token generation, TTL, single-use enforcement. Can tokens be reused after first login?

8. **Session fixation**: After login, is session ID rotated? Check `UserSessionController.create/2`.

9. **Cookie security**: Verify HttpOnly, Secure, SameSite flags on session and remember-me cookies.

10. **API key storage**: Are keys hashed before storage? Can they be enumerated? Check `lib/spectabas/api_keys.ex`.

11. **WebAuthn security**: Review `lib/spectabas/accounts/webauthn.ex`:
    - Challenge stored server-side and validated on response?
    - Origin validated in wax_ config?
    - Credential ownership enforced (user_id match on deletion)?
    - `binary_to_term(:safe)` used for stored credentials?

12. **OAuth state tokens**: Ad integration OAuth uses `Phoenix.Token.verify` with 600s max_age. Is the state token single-use? Can it be replayed?

13. **OAuth tokens in session**: During account picker flow, pending OAuth tokens are stored in the session. Are they cleared after use? What if the user abandons the flow?

### C. Authorization & Access Control

14. **Site access on all 36 pages**: Every dashboard LiveView must call `Accounts.can_access_site?/2`. Verify ALL pages, especially newer ones: Acquisition, Visitor Quality, Time to Convert, Ad Visitor Paths, Ad-to-Churn, Organic Lift, Revenue Cohorts, Buyer Patterns, Churn Risk.

15. **Role escalation**: Can analyst/viewer users modify roles, manage users, or access admin pages? Verify `RequireAdmin` plug coverage.

16. **Segment IDOR**: `get_segment!/3` scopes by user_id and site_id. Verify no bypass path exists (direct ID access without ownership check).

17. **Intent config authorization**: Any authenticated user with site access can modify `intent_config` via Settings. Should this be admin-only?

18. **API scope enforcement**: Verify every API controller action checks the correct scope. Pay attention to: `write:identify` (server-side identify), `write:events` (ecommerce transactions), `admin:sites`.

19. **Cross-tenant isolation**: Can user of Site A query ClickHouse data for Site B? Check all analytics functions for `site_id` filtering. Special attention to: ad_spend queries (FINAL), ecommerce queries, visitor detail/IP cross-reference.

20. **API key site restrictions**: Tokens scoped to specific site_ids. Verify `authorize_site/2` checks `allowed_site_ids` before allowing access.

### D. Input Validation & XSS

21. **Stored XSS via tracker data**: `url_path`, `referrer_url`, `event_name`, custom properties stored in ClickHouse and displayed in dashboards. LiveView auto-escapes `{value}` — but verify no `raw/1` usage with these values.

22. **Docs markdown renderer**: `docs_live.ex` uses custom renderer with `raw/1` output. Content is developer-defined but the search query is user input. Verify search query sanitization.

23. **Template `raw/1` audit**: Search all `.ex` files for `raw/1`, `Phoenix.HTML.raw/1`, `{:safe, ...}`. Each use must be verified safe.

24. **Reflected XSS**: URL parameters rendered back to user: `?page=` in transitions, `?filter_field=` / `?filter_value=` in visitor log, `?site_id=` in OAuth callbacks.

25. **Intent config XSS**: Path patterns from `intent_config` are only used server-side in `String.contains?/2` — not rendered in templates. Verify no template renders raw intent_config paths.

26. **Content-Security-Policy**: Review CSP plug. Is `unsafe-inline` or `unsafe-eval` allowed? Does it cover `frame-ancestors`, `object-src`, `form-action`?

### E. Rate Limiting & DoS

27. **Event collection flooding**: 300/min per IP. Can an attacker with multiple IPs exhaust the IngestBuffer (max 10K events) or overwhelm ClickHouse?

28. **Per-site rate limiting**: 1000 events/sec per site. Can an attacker target one site to suppress legitimate events?

29. **API rate limiting**: Review `ApiRateLimit` plug limits. Can authenticated API users exhaust ClickHouse with expensive queries?

30. **ClickHouse query cost**: Segment filters, date ranges, and RUM quantileIf aggregations can be expensive. API date range is capped at 12 months. Verify dashboard queries also have limits.

31. **Ad spend sync DoS**: Oban worker runs every 6h. If token refresh fails repeatedly, does it retry indefinitely? Check max_attempts.

32. **Identify endpoint abuse**: `/c/i` and `/api/v1/sites/:id/identify` — can an attacker spray arbitrary traits to exhaust Postgres storage?

### F. Data Privacy & GDPR

33. **IP handling in GDPR-on mode**: Is IP anonymized before geolocation? Is the full IP ever stored or logged?

34. **Tracking parameter stripping**: GDPR-on mode strips UTMs and click IDs from stored URLs. Verify completeness.

35. **Fingerprint privacy**: Canvas + WebGL + navigator fingerprint. Can it identify individuals? Is it the only identifier in GDPR-on mode (no cookies)?

36. **Data retention**: ClickHouse 2-year TTL on events. Verify TTL is enforced. Check Postgres retention for: visitor records, session records, API logs (30-day), audit logs.

37. **Opt-out mechanism**: `_sab_optout` cookie checked before ALL tracking (pageviews, RUM, CWV, identify, cross-domain). Verify completeness including noscript pixel `/c/p`.

38. **Ecommerce email association**: Transaction API accepts `email` to link orders to visitors. Is this data cross-site isolated? Can Site A see emails set by Site B?

### G. Infrastructure & Secrets

39. **Secrets in code**: Search for hardcoded keys/passwords. Check config files, Dockerfile, migration files. Note: migration 20260402000001 contains site domain names — verify no secrets.

40. **ClickHouse credentials**: Reader/writer passwords in environment variables. ClickHouse on private Render service — verify no public access.

41. **Ad integration encryption**: Vault module derives AES-256-GCM key from SECRET_KEY_BASE via SHA-256. Single key for all tokens. If SECRET_KEY_BASE rotates, all ad tokens become unreadable. Is there a key rotation strategy?

42. **Ad credentials in Postgres**: `sites.ad_credentials_encrypted` stores client_id/client_secret/developer_token as encrypted binary. Verify Vault encryption is applied (not just base64).

43. **Error information leakage**: Do 400/500 responses expose stack traces or internal paths? Check error views and exception handling.

44. **Public health endpoint**: `/health` returns ok/degraded. Verify no internal details leak. The token-protected utility endpoints (`/matomo-import-test`, `/send-setup-emails`, `/click-id-diag`) — what token protects them? Is it hardcoded?

45. **Admin diagnostic endpoints**: `/health/diag`, `/health/intent-diag`, `/health/optimize-ad-spend` — all admin-only. Verify they don't expose sensitive data (full IP addresses, API keys, ClickHouse passwords).

### H. Tracker Security

46. **Origin validation bypass**: Review `check_origin/2` in CollectController. Allows any subdomain of parent domain. Can an attacker on `evil.example.com` inject events for `b.example.com`?

47. **Reverse proxy (data-proxy) security**: When `data-proxy` is set, tracker sends beacons through the main domain. Does this bypass origin validation? Can a malicious proxy inject events?

48. **Public key enumeration**: `/c/e` returns 204 for found and not-found sites. Verify consistent response to prevent enumeration.

49. **Click ID injection**: Attacker sends fake gclid/msclkid/fbclid values to pollute ad attribution data. These flow into ROAS calculations. Is there any validation?

50. **RUM data injection**: Fake `_rum` or `_cwv` events with extreme values. Any bounds checking on performance metric values?

51. **Ecommerce event injection**: Fake `ecommerce_order` events with inflated revenue. The collection endpoint is public — is there any authentication for ecommerce events?

### I. Dependency Security

52. **Hex package audit**: Run `mix deps.audit`. Check: `wax_`, `tzdata`, `hammer`, `oban`, `swoosh`, `req`.

53. **Chart.js**: Vendored at `assets/vendor/chart.umd.js`. Check version for known CVEs.

54. **GeoIP database integrity**: MMDB downloads verified with checksums? MITM risk?

### J. Business Logic

55. **Visitor deduplication bypass**: GDPR-on uses fingerprint dedup. Can attacker generate many unique fingerprints to inflate counts?

56. **Goal/funnel manipulation**: Fake custom events can trigger goal completions and advance funnel stages. Document as limitation or add server-side validation.

57. **Ad spend data integrity**: ClickHouse `ad_spend` uses ReplacingMergeTree. Without FINAL, duplicate rows inflate totals. Verify ALL ad_spend queries use FINAL (fixed in v4.5.0 — confirm no regression).

58. **Intent classification manipulation**: Attacker sends events with URLs matching buying/engaging paths to inflate intent metrics. Intent is classified at ingest based on URL path — no authentication required.

59. **Spam filter bypass**: SpamFilter excludes known spam referrer domains. Attacker can use unknown domains or empty referrers. Auto-detection worker may have false negatives.

60. **Email report content injection**: Email reports include page paths and source names from ClickHouse data. If an attacker injects malicious URL paths, could they appear in HTML emails? Check email template escaping.

---

## Previous Audit Results

### Audit v1 (v0.8.0) — 10 findings fixed
1. Health endpoints authenticated 2. Opt-out cookie check 3. Login rate limiting
4. Invitation email verification 5. Null byte sanitization 6. Buffer overflow protection
7. ClickHouse TTL 8. MMDB integrity checks 9. Input validation 10. Session fixation

### Audit v2 (v1.6.0) — 10 findings fixed
1. WebAuthn binary_to_term :safe 2. WebAuthn credential ownership 3. Pixel opt-out
4. Origin validation 5. API date range cap 6. Config secrets removed
7. CSP object-src 8. Cookie security 9. Health endpoint limited 10. SQL parameterization

### Audit v3 (v2.6.0) — 5 findings fixed
1. SQL injection in visitor_log 2. Segment IDOR 3. Origin validation on /c/i and /c/x
4. Silent event loss 5. Deferred stats parallelized

**Verify all 25 previous findings remain effective and haven't regressed.**

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Category**: Which section (A-J) above
3. **Location**: File path and line number
4. **Description**: What the vulnerability is
5. **Exploit scenario**: How an attacker could exploit it
6. **Remediation**: Specific code change to fix it

Conclude with a prioritized summary of the top 10 findings.
