# Spectabas Security Audit Prompt

You are performing a comprehensive security audit of Spectabas, a multi-tenant web analytics SaaS platform built with Elixir/Phoenix. The platform collects visitor behavior data via a JavaScript tracker, stores events in ClickHouse, and serves analytics dashboards via Phoenix LiveView.

## System Architecture

- **Elixir 1.17 / Phoenix 1.8** with LiveView
- **PostgreSQL** — users, sessions, visitors, invitations, audit logs, sites, API keys
- **ClickHouse** — analytics events (pageviews, custom events, ecommerce, RUM, CWV)
- **Render** — Docker-based deployment with auto-deploy on push to main
- **Resend** — transactional email delivery
- **Geolix** — IP geolocation (DB-IP + MaxMind GeoLite2 MMDB files)
- **tzdata** — timezone database for site-local date boundaries
- **wax_** — WebAuthn/FIDO2 passkey 2FA

## Attack Surface

### 1. Event Collection Endpoint (`/c/e`, `/c/p`, `/c/i`, `/c/x`, `/c/o`)
- Public, unauthenticated POST/GET endpoints
- Accepts JSON payloads from any origin (CORS enabled)
- Rate-limited via Hammer (300/min per IP for collect, 10/min for login)
- Validates payload via Ecto embedded schema (CollectPayload)
- Resolves site by public key or domain
- Origin/Referer validation against allowed domains
- Accepts custom event types: `pageview`, `custom`, `duration`, `ecommerce_order`, `ecommerce_item`, `xdtoken`
- Custom events include `_rum` (navigation timing), `_cwv` (Core Web Vitals), `_form_abuse` (form abuse signals)

### 2. JavaScript Tracker (`/assets/v1.js`)
- Served from customer analytics subdomains (e.g., `b.example.com`)
- Sends beacons with visitor ID, session ID, page URL, referrer, screen dimensions
- GDPR mode: cookie-based (off) or fingerprint-based (on)
- Cross-domain token exchange via `/c/x`
- Client-side bot detection signals (`_bot`, `_hi`)
- Browser fingerprinting: canvas, WebGL, navigator signals, MurmurHash3
- Form abuse detection: monitors submit frequency, paste events, click patterns
- RUM collection: Performance API navigation timing, PerformanceObserver for CWV
- Public JavaScript API: `Spectabas.track()`, `Spectabas.identify()`, `Spectabas.optOut()`, `Spectabas.ecommerce.addOrder()`, `Spectabas.ecommerce.addItem()`

### 3. Dashboard (LiveView, authenticated)
- All analytics queries interpolate values using `ClickHouse.param/1`
- Segment filters build WHERE clauses from user input
- Visitor profiles show IP addresses and cross-reference other visitors
- Admin pages manage users, sites, invitations, audit logs
- Performance dashboard renders RUM data from custom event properties
- Documentation page uses custom markdown renderer with `raw/1` output

### 4. REST API (`/api/v1/*`)
- Bearer token authentication via API keys
- Endpoints: stats, pages, sources, countries, devices, realtime
- Date range parameters parsed from query string

### 5. Authentication & Authorization
- Phoenix 1.8 scope-based auth (current_scope, not current_user)
- Magic link login (email token)
- Password authentication
- Optional TOTP 2FA (NimbleTOTP)
- Optional WebAuthn/passkey 2FA (wax_ library)
- Role-based access: superadmin, admin, analyst, viewer
- Invitation system with token-based acceptance
- Session tokens in cookies
- Admin can force 2FA per user

### 6. Infrastructure
- Docker deployment on Render (non-root runtime user)
- ClickHouse with separate reader/writer users
- PostgreSQL with Ecto
- MaxMind license key in environment variable
- Resend API key for email
- Render API key for custom domain registration
- Health endpoint returns detailed service status (postgres, clickhouse, buffer state)

---

## Audit Checklist — Review EVERY item below

### A. SQL/Query Injection

1. **ClickHouse injection via `ClickHouse.param/1`**: Review the `param/1` function in `lib/spectabas/clickhouse.ex`. Does it properly escape all value types (strings, integers, floats, nil)? Can a malicious string bypass the escaping? Check for single-quote escaping, backslash escaping, and null byte handling.

2. **Segment filter injection**: Review `lib/spectabas/analytics/segment.ex`. The `to_sql/1` function builds WHERE clauses from user-supplied field names, operators, and values. Check:
   - Can a user supply a field name that isn't in `@allowed_fields` and execute arbitrary SQL?
   - Can the operator value be something other than `is/is_not/contains/not_contains`?
   - Can the value contain SQL injection payloads that bypass `ClickHouse.param/1`?
   - Are field names interpolated directly into SQL without parameterization?

3. **Ecto SQL injection**: Check all `Ecto.Query` usage for raw SQL fragments. Search for `fragment`, `from`, raw SQL strings in Repo calls.

4. **ClickHouse `execute/1`**: This function runs SQL with write credentials. Check all callers — is any user input reaching this function unsanitized?

5. **RUM query injection via JSON properties**: RUM/CWV queries use `JSONExtractString(properties, 'key')` where key names are hardcoded. But verify that no user-supplied key names are interpolated into `JSONExtractString` calls anywhere in the analytics module.

### B. Authentication & Session Security

6. **Magic link token security**: Review `UserToken` — how are login tokens generated, stored, and validated? What's the TTL? Can tokens be reused? Are they single-use?

7. **Session fixation**: After login, is the session ID rotated? Check `UserSessionController.create/2`.

8. **Cookie security**: Check cookie flags — HttpOnly, Secure, SameSite. Review the session configuration in `config.exs` and `runtime.exs`.

9. **Password storage**: How are passwords hashed? Check `User` schema and `register_user/1`. Is bcrypt/argon2 used with appropriate cost?

10. **TOTP 2FA**: Review the TOTP implementation. Are backup codes provided? Is the TOTP secret stored encrypted?

11. **WebAuthn/passkey 2FA**: Review `lib/spectabas/accounts/webauthn.ex`. Check:
    - Is the challenge stored server-side and validated on response?
    - Is the origin validated in the wax_ configuration?
    - Can an attacker register a credential for another user?
    - Is the credential ID stored and checked for uniqueness?
    - Are attestation and assertion properly verified?

12. **API key security**: Review `lib/spectabas/api_keys.ex`. How are keys generated, stored, and verified? Are they hashed before storage? Can they be enumerated?

### C. Authorization & Access Control

13. **Site access checks**: Review `Accounts.can_access_site?/2`. Does every dashboard LiveView and API endpoint check site access? Look for pages that might bypass this check. There are now 23+ dashboard pages — verify all of them.

14. **Role escalation**: Can a viewer or analyst modify their own role? Review all `handle_event` handlers in admin LiveViews. Is the admin role check enforced in the `RequireAdmin` plug?

15. **Invitation token security**: Review the invitation flow. Can an attacker:
    - Enumerate valid invitation tokens?
    - Accept an invitation with a different email than intended?
    - Use an expired invitation?
    - Replay an already-accepted invitation?

16. **Cross-tenant data access**: Can a user with access to Site A query data for Site B? Check all analytics functions for proper `site_id` filtering. Pay special attention to the new RUM queries (`rum_overview`, `rum_web_vitals`, `rum_by_page`, `rum_by_device`, `rum_vitals_by_page`, `rum_vitals_summary`).

### D. Input Validation & XSS

17. **Stored XSS via event data**: The tracker sends `url_path`, `referrer_url`, `event_name`, and custom properties (`p`). These are stored in ClickHouse and displayed in dashboards. Check:
    - Are these values escaped when rendered in LiveView templates?
    - Can a malicious `url_path` like `<script>alert(1)</script>` execute in the dashboard?
    - Are custom properties (`p` map) sanitized?
    - Are RUM/CWV property values (from the `properties` JSON column) escaped when displayed on the Performance page?

18. **XSS via documentation markdown renderer**: The docs page (`lib/spectabas_web/live/docs_live.ex`) uses a custom markdown renderer that outputs HTML via `raw/1`. Review:
    - Does the `escape/1` function properly sanitize all user-controllable content before `raw/1` output?
    - Can markdown content bypass escaping (e.g., via nested backticks, HTML entities)?
    - The renderer handles: paragraphs, headings, code blocks, lists, tables, blockquotes, horizontal rules. Check each for escaping completeness.
    - Note: the docs content is developer-defined (not user input), but the search query is user input — verify it's not rendered unsanitized.

19. **XSS via HEEx templates**: LiveView's `{value}` interpolation auto-escapes by default. But check for any use of `raw/1`, `Phoenix.HTML.raw/1`, or `{:safe, ...}` that bypasses escaping. Search all `.ex` and `.heex` files.

20. **Reflected XSS**: Check URL parameters that are rendered back to the user (e.g., `?page=/path` in transitions, `?filter_field=...` in visitor log).

21. **Content-Security-Policy**: Review the CSP plug at `lib/spectabas_web/plugs/content_security_policy.ex`. Is it restrictive enough? Does it allow `unsafe-inline` or `unsafe-eval`?

### E. Rate Limiting & DoS

22. **Event collection rate limiting**: Review the rate limit configuration. What are the limits per IP? Can an attacker flood the ClickHouse buffer? Current: 300/min per IP for collect.

23. **Login rate limiting**: Check rate limits on `/users/log-in`, password reset, and TOTP verification. Current: 10/min per IP.

24. **API rate limiting**: Review `ApiRateLimit` plug. What are the limits?

25. **IngestBuffer DoS**: The buffer batches events and flushes every 500ms. What happens if an attacker sends millions of events? Is there a max batch size? Can it crash the GenServer? Current max: 10,000 events.

26. **ClickHouse resource exhaustion**: Can a user craft a segment filter or date range that causes an expensive ClickHouse query? (e.g., 12-month range with no LIMIT, complex LIKE patterns, RUM queries with quantileIf aggregations).

27. **Identify endpoint abuse**: The `/c/i` endpoint associates traits with visitors. Can an attacker spray arbitrary traits at scale to exhaust storage or pollute visitor data?

### F. Data Privacy & GDPR

28. **IP anonymization**: In GDPR-on mode, is the IP anonymized BEFORE the Geolix lookup or after? Is the full IP ever stored or logged?

29. **Tracking parameter stripping**: In GDPR-on mode, are UTM params, gclid, fbclid properly stripped from stored URLs?

30. **Browser fingerprinting privacy**: Review the fingerprint generation in both `s.js` (client-side: canvas, WebGL, navigator signals) and `ingest.ex` (server-side). The client-side fingerprint uses canvas pixel data, WebGL renderer strings, and 15+ browser signals. Check:
    - Can the fingerprint be reversed to identify a specific person?
    - Is the fingerprint stable enough to track users across sessions but not so unique it becomes PII?
    - In GDPR-on mode, is the fingerprint the ONLY identifier (no cookies)?

31. **Data retention**: Is there a TTL on ClickHouse events? What about PostgreSQL visitor/session records? Check the ClickHouse TTL configuration. Current: 2-year TTL.

32. **Opt-out mechanism**: Review the `/c/o` endpoint and `_sab_optout` cookie. Is it respected in all tracking scenarios? Check that the tracker checks the cookie before sending ANY data (including RUM and CWV events).

33. **Identify endpoint privacy**: `Spectabas.identify()` lets websites associate email, user_id, etc. with visitors. Is this data protected? Can another site's admin see traits set by a different site?

### G. Infrastructure Security

34. **Secrets in code**: Search for hardcoded API keys, passwords, or tokens in the codebase. Check `.env` files, config files, and the Dockerfile.

35. **ClickHouse credentials**: Are the reader/writer passwords sufficiently strong? Are they transmitted securely (HTTP vs HTTPS)? ClickHouse is on a private Render service — verify it's not publicly accessible.

36. **Docker security**: Review the Dockerfile. Does the runtime container run as non-root? Are unnecessary packages installed?

37. **Error information leakage**: Do error responses (400, 500) expose stack traces, database schemas, or internal paths to users?

38. **Health endpoint information disclosure**: `/health` now returns detailed service status (`postgres`, `clickhouse`, `ingest_buffer`). This is public and unauthenticated. Does it reveal too much about internal architecture? Should it be limited to just `ok/error`?

39. **Diagnostic endpoints**: `/health/diag`, `/health/dashboard-test`, `/health/audit-test`, `/health/backfill-geo` — are these authenticated? Verify they require admin auth. What sensitive data do they expose (IP addresses, event data, site public keys)?

### H. Tracker Security

40. **Origin validation bypass**: Review `check_origin/2` in CollectController. Can an attacker spoof the Origin/Referer headers to inject events for a site they don't own?

41. **Public key enumeration**: Can an attacker enumerate valid site public keys by testing the `/c/e` endpoint? The endpoint returns 204 for both found and not-found sites — verify this is consistent.

42. **Cross-domain token security**: Review the xdomain token system. Is the token strong enough? Can it be brute-forced? Is it time-limited? Can a token be replayed?

43. **Event payload manipulation**: Can an attacker send fake events with arbitrary `visitor_id`, `session_id`, or `ip_address` values to pollute analytics data?

44. **RUM data injection**: Can an attacker send fake `_rum` or `_cwv` events with extreme values (e.g., page_load = "999999999") to skew performance metrics? Is there any validation on the property values beyond "must be a string under 256 chars"?

45. **Form abuse detection evasion**: The client-side form abuse detector can be trivially bypassed by modifying or not loading the tracker. Is this documented as a limitation? Is the `_form_abuse` event treated as advisory, not authoritative?

46. **Tracker script tampering**: The tracker is served with `Cache-Control: public, max-age=86400`. Could an attacker serving from a compromised CDN or MITM inject malicious JavaScript? Is Subresource Integrity (SRI) feasible for the tracker?

### I. Dependency Security

47. **Hex package audit**: Run `mix deps.audit` or manually check for known vulnerabilities in dependencies. Pay attention to: `wax_`, `tzdata`, `hammer`, `oban`, `swoosh`.

48. **JavaScript dependencies**: Check `assets/vendor/chart.umd.js` for known vulnerabilities. Is it the latest version?

49. **GeoIP database integrity**: Are the DB-IP and MaxMind downloads verified (checksums)? Could a MITM attack substitute a malicious MMDB file?

50. **tzdata updates**: The tzdata library downloads timezone data. Is the download verified? Could a compromised tzdata source affect date boundary calculations?

### J. Business Logic

51. **Ecommerce data integrity**: Can an attacker send fake `ecommerce_order` events with inflated revenue to manipulate the ecommerce dashboard?

52. **Visitor deduplication bypass**: The system deduplicates visitors by fingerprint when cookies are unavailable. Can an attacker generate many unique fingerprints to inflate visitor counts?

53. **Anomaly detection manipulation**: The insights/anomaly detector compares last 7 days vs prior 7 days. Can an attacker poison the baseline period to suppress or trigger false alerts?

54. **Goal/funnel manipulation**: Can fake custom events trigger goal conversions or advance funnel stages to distort conversion metrics?

---

## Previous Audit Results (v0.8.0)

The following 10 findings were identified and fixed in the v0.8.0 security audit:

1. Health endpoints authenticated (now require admin)
2. Opt-out cookie check added to collection endpoint
3. Login rate limiting added (10/min/IP)
4. Invitation email verification (matches intended recipient)
5. Null byte sanitization on all user input
6. IngestBuffer max size limit (10K events)
7. ClickHouse TTL (2-year event expiry)
8. MMDB integrity checks on GeoIP load
9. Input validation strengthened on collection endpoints
10. Session fixation — tokens regenerated on auth state changes

**Verify all 10 remain effective and haven't been regressed.**

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
