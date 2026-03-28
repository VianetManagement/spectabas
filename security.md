# Spectabas Security Audit Prompt

You are performing a comprehensive security audit of Spectabas, a multi-tenant web analytics SaaS platform built with Elixir/Phoenix. The platform collects visitor behavior data via a JavaScript tracker, stores events in ClickHouse, and serves analytics dashboards via Phoenix LiveView.

## System Architecture

- **Elixir 1.17 / Phoenix 1.8** with LiveView
- **PostgreSQL** — users, sessions, visitors, invitations, audit logs, sites, API keys
- **ClickHouse** — analytics events (pageviews, custom events, ecommerce)
- **Render** — Docker-based deployment with auto-deploy on push to main
- **Resend** — transactional email delivery
- **Geolix** — IP geolocation (DB-IP + MaxMind GeoLite2 MMDB files)

## Attack Surface

### 1. Event Collection Endpoint (`/c/e`, `/c/p`, `/c/i`, `/c/x`, `/c/o`)
- Public, unauthenticated POST/GET endpoints
- Accepts JSON payloads from any origin (CORS enabled)
- Rate-limited via Hammer
- Validates payload via Ecto embedded schema (CollectPayload)
- Resolves site by public key or domain
- Origin/Referer validation against allowed domains

### 2. JavaScript Tracker (`/assets/v1.js`)
- Served from customer analytics subdomains (e.g., `b.example.com`)
- Sends beacons with visitor ID, session ID, page URL, referrer, screen dimensions
- GDPR mode: cookie-based (off) or fingerprint-based (on)
- Cross-domain token exchange via `/c/x`
- Client-side bot detection signals (_bot, _hi)

### 3. Dashboard (LiveView, authenticated)
- All analytics queries interpolate values using `ClickHouse.param/1`
- Segment filters build WHERE clauses from user input
- Visitor profiles show IP addresses and cross-reference other visitors
- Admin pages manage users, sites, invitations, audit logs

### 4. REST API (`/api/v1/*`)
- Bearer token authentication via API keys
- Endpoints: stats, pages, sources, countries, devices, realtime
- Date range parameters parsed from query string

### 5. Authentication & Authorization
- Phoenix 1.8 scope-based auth (current_scope, not current_user)
- Magic link login (email token)
- Password authentication
- Optional TOTP 2FA
- Role-based access: superadmin, admin, analyst, viewer
- Invitation system with token-based acceptance
- Session tokens in cookies

### 6. Infrastructure
- Docker deployment on Render
- ClickHouse with separate reader/writer users
- PostgreSQL with Ecto
- MaxMind license key in environment variable
- Resend API key for email

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

### B. Authentication & Session Security

5. **Magic link token security**: Review `UserToken` — how are login tokens generated, stored, and validated? What's the TTL? Can tokens be reused? Are they single-use?

6. **Session fixation**: After login, is the session ID rotated? Check `UserSessionController.create/2`.

7. **Cookie security**: Check cookie flags — HttpOnly, Secure, SameSite. Review the session configuration in `config.exs` and `runtime.exs`.

8. **Password storage**: How are passwords hashed? Check `User` schema and `register_user/1`. Is bcrypt/argon2 used with appropriate cost?

9. **TOTP 2FA**: Review the TOTP implementation. Are backup codes provided? Is the TOTP secret stored encrypted?

10. **API key security**: Review `lib/spectabas/api_keys.ex`. How are keys generated, stored, and verified? Are they hashed before storage? Can they be enumerated?

### C. Authorization & Access Control

11. **Site access checks**: Review `Accounts.can_access_site?/2`. Does every dashboard LiveView and API endpoint check site access? Look for pages that might bypass this check.

12. **Role escalation**: Can a viewer or analyst modify their own role? Review all `handle_event` handlers in admin LiveViews. Is the admin role check enforced in the `RequireAdmin` plug?

13. **Invitation token security**: Review the invitation flow. Can an attacker:
    - Enumerate valid invitation tokens?
    - Accept an invitation with a different email than intended?
    - Use an expired invitation?
    - Replay an already-accepted invitation?

14. **Cross-tenant data access**: Can a user with access to Site A query data for Site B? Check all analytics functions for proper `site_id` filtering.

### D. Input Validation & XSS

15. **Stored XSS via event data**: The tracker sends `url_path`, `referrer_url`, `event_name`, and custom properties (`p`). These are stored in ClickHouse and displayed in dashboards. Check:
    - Are these values escaped when rendered in LiveView templates?
    - Can a malicious `url_path` like `<script>alert(1)</script>` execute in the dashboard?
    - Are custom properties (`p` map) sanitized?

16. **XSS via HEEx templates**: LiveView's `{value}` interpolation auto-escapes by default. But check for any use of `raw/1`, `Phoenix.HTML.raw/1`, or `{:safe, ...}` that bypasses escaping. Search all `.ex` and `.heex` files.

17. **Reflected XSS**: Check URL parameters that are rendered back to the user (e.g., `?page=/path` in transitions, `?filter_field=...` in visitor log).

18. **Content-Security-Policy**: Review the CSP plug at `lib/spectabas_web/plugs/content_security_policy.ex`. Is it restrictive enough? Does it allow `unsafe-inline` or `unsafe-eval`?

### E. Rate Limiting & DoS

19. **Event collection rate limiting**: Review the rate limit configuration. What are the limits per IP? Can an attacker flood the ClickHouse buffer?

20. **Login rate limiting**: Check rate limits on `/users/log-in`, password reset, and TOTP verification.

21. **API rate limiting**: Review `ApiRateLimit` plug. What are the limits?

22. **IngestBuffer DoS**: The buffer batches events and flushes every 500ms. What happens if an attacker sends millions of events? Is there a max batch size? Can it crash the GenServer?

23. **ClickHouse resource exhaustion**: Can a user craft a segment filter or date range that causes an expensive ClickHouse query? (e.g., 12-month range with no LIMIT, complex LIKE patterns)

### F. Data Privacy & GDPR

24. **IP anonymization**: In GDPR-on mode, is the IP anonymized BEFORE the Geolix lookup or after? Is the full IP ever stored or logged?

25. **Tracking parameter stripping**: In GDPR-on mode, are UTM params, gclid, fbclid properly stripped from stored URLs?

26. **Visitor fingerprinting**: Review the fingerprint generation in `ingest.ex`. What data is used? Can it be reversed to identify a person?

27. **Data retention**: Is there a TTL on ClickHouse events? What about PostgreSQL visitor/session records? Check the ClickHouse TTL configuration.

28. **Opt-out mechanism**: Review the `/c/o` endpoint and `_sab_optout` cookie. Is it respected in all tracking scenarios?

### G. Infrastructure Security

29. **Secrets in code**: Search for hardcoded API keys, passwords, or tokens in the codebase. Check `.env` files, config files, and the Dockerfile.

30. **ClickHouse credentials**: Are the reader/writer passwords sufficiently strong? Are they transmitted securely (HTTP vs HTTPS)?

31. **Docker security**: Review the Dockerfile. Does the runtime container run as non-root? Are unnecessary packages installed?

32. **Error information leakage**: Do error responses (400, 500) expose stack traces, database schemas, or internal paths to users?

33. **Health/diagnostic endpoints**: `/health/diag`, `/health/dashboard-test`, `/health/audit-test`, `/health/backfill-geo` — are these authenticated? Should they be? What sensitive data do they expose?

### H. Tracker Security

34. **Origin validation bypass**: Review `check_origin/2` in CollectController. Can an attacker spoof the Origin/Referer headers to inject events for a site they don't own?

35. **Public key enumeration**: Can an attacker enumerate valid site public keys by testing the `/c/e` endpoint?

36. **Cross-domain token security**: Review the xdomain token system. Is the token strong enough? Can it be brute-forced? Is it time-limited?

37. **Event payload manipulation**: Can an attacker send fake events with arbitrary `visitor_id`, `session_id`, or `ip_address` values to pollute analytics data?

### I. Dependency Security

38. **Hex package audit**: Run `mix deps.audit` or manually check for known vulnerabilities in dependencies.

39. **JavaScript dependencies**: Check `assets/vendor/chart.umd.js` and `assets/node_modules/` for known vulnerabilities.

40. **GeoIP database integrity**: Are the DB-IP and MaxMind downloads verified (checksums)? Could a MITM attack substitute a malicious MMDB file?

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Category**: Which section (A-I) above
3. **Location**: File path and line number
4. **Description**: What the vulnerability is
5. **Exploit scenario**: How an attacker could exploit it
6. **Remediation**: Specific code change to fix it

Conclude with a prioritized summary of the top 10 findings.
