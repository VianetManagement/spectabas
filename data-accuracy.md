# Spectabas Data Accuracy Audit Prompt

You are auditing whether Spectabas analytics numbers are correct. Inaccurate analytics are worse than no analytics — site owners make business decisions based on these numbers. Every metric shown in the dashboard must be verifiable and trustworthy.

## What to Audit

For each metric, trace the full pipeline: tracker collection → payload validation → ingest enrichment → ClickHouse storage → analytics query → dashboard display. Identify anywhere data can be lost, double-counted, miscategorized, or miscalculated.

---

## Audit Checklist

### A. Visitor Counting

1. **Unique visitor accuracy**: Review the full visitor resolution flow in `lib/spectabas/events/ingest.ex` (`resolve_visitor`). Trace every path: GDPR-off with cookie, GDPR-off without cookie (fingerprint fallback), GDPR-on (fingerprint only). For each path, answer: can the same human be counted as two visitors? Can two humans be counted as one visitor?

2. **Fingerprint collision rate**: The client fingerprint uses canvas + WebGL + navigator signals via MurmurHash3 (32-bit). With 32 bits, collision probability is ~50% at 77K visitors (birthday problem). For a site with 100K monthly visitors, how many false merges? Is this acceptable? Should the hash be 64-bit?

3. **Fingerprint stability**: Does the same browser produce the same fingerprint across sessions? What changes it: browser update, OS update, screen resolution change, new GPU driver, font installation? How often do legitimate visitors get a new fingerprint (splitting into two visitors)?

4. **Cookie vs fingerprint visitor ID mismatch**: When GDPR is off and cookies work, the visitor ID is the cookie value. When cookies are blocked, it falls back to fingerprint. If a visitor has cookies on visit 1 (gets cookie ID "abc") then cookies blocked on visit 2 (gets fingerprint ID "fp_xyz"), they're counted as two visitors. How often does this happen? Is there reconciliation?

5. **Cross-device visitors**: A visitor on phone and desktop is always two visitors. This is expected but should be documented. Does the identify() API help here?

6. **Bot inflation**: Review bot detection in `ingest.ex`. Are detected bots excluded from visitor counts? Check: does `ip_is_bot` filter apply to `uniqExact(visitor_id)` in overview_stats? Or are bots counted as visitors and only flagged?

### B. Pageview Counting

7. **Double pageview on SPA navigation**: The tracker patches `history.pushState` and listens for `popstate`. If a SPA framework calls `pushState` multiple times for one navigation (e.g., redirect chains), are multiple pageviews fired? Test with: Next.js router, React Router, Vue Router.

8. **Missing pageviews**: When does a pageview NOT get counted? Check: JavaScript disabled (noscript pixel fallback), ad blocker blocking beacon, rate-limited visitor, network error on sendBeacon, opted-out visitor. Are these edge cases documented?

9. **Pageview vs event deduplication**: If the same visitor rapidly refreshes a page, does each refresh count as a separate pageview? Is there any dedup window? Should there be?

10. **URL normalization**: Review URL handling in `ingest.ex` (`normalize_url`). Are these treated as the same page or different: `/page` vs `/page/` vs `/page?ref=123` vs `/PAGE`? Check: trailing slashes, query parameters, hash fragments, case sensitivity.

### C. Session Accuracy

11. **Session definition**: Review `lib/spectabas/sessions.ex`. What defines a session boundary? Timeout duration? New referrer? Midnight reset? Does it match industry standards (Google Analytics: 30min inactivity, new campaign, midnight)?

12. **Session attribution**: When a session starts, what referrer/UTM is attributed? If a visitor arrives via Google, leaves, and returns via email link within the session timeout, which source gets credit?

13. **Duration calculation**: Review the duration event flow. The tracker sends `duration` events on `visibilitychange`. Is the duration per-page or per-session? Are multi-tab visits handled correctly? What about: user opens page, switches to another app for 30 minutes, comes back — is that 30 minutes of duration?

14. **Bounce rate calculation**: Review the bounce rate query in `overview_stats`. It uses `countIf(pv = 1 AND dur = 0)` per session. Is this correct? A visitor who views one page but scrolls for 5 minutes and sends a duration event — are they a bounce? What about custom events — does a visitor who views one page but triggers a custom event count as a bounce?

### D. Geographic Accuracy

15. **IP-to-location accuracy**: DB-IP Lite has ~70% city-level accuracy. MaxMind GeoLite2 is similar. Are accuracy expectations documented for users? Do they understand that city-level data is approximate?

16. **VPN/proxy misattribution**: A visitor using a VPN in Amsterdam but physically in New York is attributed to Amsterdam. With ~30% of traffic through VPNs, how much does this skew geographic data? Is the VPN flag (`ip_is_vpn`) used to qualify geographic confidence?

17. **IP anonymization impact**: In GDPR-on mode, IPs are anonymized (last octet zeroed). Does this happen before or after the GeoIP lookup? If after, the stored anonymized IP can't be re-looked-up. If before, city-level accuracy drops significantly.

18. **Timezone attribution**: The site timezone is used for "today" boundaries. But visitor timezone (from IP) may differ. When the dashboard shows "visitors today", it means "visitors during today in the site's timezone" — is this clearly communicated?

### E. Referrer & Source Accuracy

19. **Referrer stripping**: Modern browsers increasingly strip referrers (Referrer-Policy: strict-origin). A visit from `https://google.com/search?q=foo` may arrive as just `https://google.com`. Is the referrer_domain extraction robust for stripped referrers?

20. **Self-referral filtering**: Review `self_referrer_domains` in analytics.ex. Does it correctly exclude the analytics subdomain AND the parent domain from referrer stats? What about www vs non-www?

21. **UTM parameter persistence**: In GDPR-off mode, UTMs are stored in sessionStorage. If a visitor arrives via `?utm_source=google`, navigates to another page (losing the query param), is the UTM still attributed to the session? What about in GDPR-on mode where sessionStorage isn't used for UTMs?

22. **Direct vs unknown source**: When referrer is empty, it's classified as "Direct". But empty referrer can also mean: HTTPS→HTTP downgrade, bookmarks, mobile app links, email client links. Is "Direct" overinflated?

### F. Real User Monitoring Accuracy

23. **Navigation timing correctness**: Review the RUM collection in `s.js`. Are the timing calculations correct? Specifically: is TTFB `responseStart - requestStart` or `responseStart - navigationStart`? (Industry standard is the former.) Is page_load `loadEventEnd - navigationStart` correct?

24. **RUM sampling bias**: RUM data is only collected from visitors who stay long enough for the polling to fire (500ms minimum). This inherently excludes the fastest bounces — the visitors with the worst experience. Does this bias the metrics toward better-than-reality?

25. **Core Web Vitals accuracy**: LCP uses `PerformanceObserver` with `buffered: true`. CLS accumulates all layout shifts without recent input. FID uses first-input timing. Are these implementations aligned with Google's web-vitals library methodology?

26. **Device type attribution in RUM**: The `rum_by_device` query joins RUM events with `device_type` from UA parsing. Is device_type set on `_rum` events? Or only on `pageview` events? If the latter, the join may fail.

### G. Ecommerce Accuracy

27. **Revenue double-counting**: Can the same `order_id` be submitted multiple times (page refresh on confirmation page)? Is there dedup on order_id? If not, revenue is inflated.

28. **Currency handling**: Orders include a `currency` field. Are different currencies mixed in the revenue total? Is there currency conversion?

### H. Time & Timezone Accuracy

29. **Timeseries bucket alignment**: Review `generate_buckets` in analytics.ex. When viewing "7d" for a site in `America/New_York`, do the daily buckets align to midnight Eastern or midnight UTC? Do the ClickHouse `toDate(toTimezone(timestamp, tz))` buckets match the Elixir-generated bucket labels?

30. **DST transition handling**: When clocks spring forward (2am→3am) or fall back (2am→1am), do hourly buckets have gaps or overlaps? Does `DateTime.shift_zone` handle the ambiguous hour correctly?

31. **"Today" consistency**: The "Today" preset and the "Your Sites" index both use `period_to_date_range(:today, tz)`. Is "today" consistent across: the stats query, the timeseries query, the chart bucket labels, and the stat card display?

32. **Event timestamp accuracy**: Events use `DateTime.utc_now()` at ingest time, not the client's timestamp. If a visitor's beacon is delayed (network queue, sendBeacon batching), the event timestamp may be seconds or minutes after the actual action. Does this matter for hourly bucketing?

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Metric affected**: Which dashboard number is wrong
3. **Direction of error**: Overcounting, undercounting, or miscategorized
4. **Magnitude estimate**: How far off (e.g., "~5% overcounting on sites with 100K+ visitors")
5. **Location**: File path and relevant code
6. **Remediation**: Specific fix or documentation update

Conclude with a prioritized summary: which metrics can users trust, which need caveats, and which need code fixes.
