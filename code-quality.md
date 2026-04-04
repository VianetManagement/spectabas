# Spectabas Code Quality & Maintainability Audit Prompt

You are auditing the Spectabas codebase for code quality, maintainability, and technical debt. The project has grown rapidly from a simple tracker to a 38-page analytics dashboard with multi-tenancy, payment integrations (Stripe/Braintree), search console integrations (Google/Bing), MRR tracking, and customer LTV. Rapid iteration leaves patterns that should be consolidated, dead code that should be removed, and conventions that should be enforced.

---

## Audit Checklist

### A. Code Duplication

1. **range_to_atom duplication**: The pattern `defp range_to_atom("24h"), do: :day` is duplicated in 16+ dashboard LiveView files. Review all instances — are they all identical? Should this be a shared function in a helper module or the SidebarComponent?

2. **to_num/to_float duplication**: These ClickHouse-string-to-number conversion helpers are defined in multiple places. TypeHelpers module exists — is it used everywhere, or do some files define their own?

3. **Date range construction duplication**: Many pages construct date ranges from presets in slightly different ways. Compare: site_live.ex (Date-based with timezone), sub-pages (atom-based via range_to_atom), API controller (UTC DateTime), index_live (Analytics.period_to_date_range). Should there be one canonical way?

4. **Authorization check pattern**: Every LiveView mount does `unless Accounts.can_access_site?(user, site)`. Is this consistently implemented across all 38 pages? Are there any pages that skip it? Could this be a shared on_mount hook?

5. **Table rendering patterns**: Review table HTML across dashboard pages. Is the table markup consistent? Could there be a shared table component?

6. **ecommerce_source_filter calls**: The `ecommerce_source_filter(site)` is injected into 26+ ecommerce queries. Are there any ecommerce queries that MISS this filter? Check analytics.ex, anomaly_detector.ex, mrr_live.ex, and any new files.

### B. Dead Code & Unused Features

7. **Unused functions**: Search for functions defined but never called. Check: `ecommerce_dedup/0` (should be dead code now), public functions in analytics.ex, helper functions in LiveView modules.

8. **Unreachable code paths**: Review pattern matches and case/cond branches that can never be reached.

9. **Commented-out code**: Search for commented code blocks that should be removed.

10. **Unused imports/aliases**: Check for `alias` or `import` statements that aren't used in the module. The `--warnings-as-errors` flag should catch these, but verify.

11. **Stale configuration**: Review config files for settings that reference removed features or unused environment variables.

12. **Diagnostic endpoints**: Are `/ecom-diag`, `/fix-ch-schema` endpoints still needed in production? Should they be removed or moved behind admin auth?

### C. Naming Conventions

13. **Consistent column naming**: ClickHouse columns use: `ip_country`, `duration_s`, `referrer_url`. Do all queries reference the correct column names? Have any column name mismatches been introduced? Check: `import_source`, `refund_amount` (new columns).

14. **Order ID prefixes**: Stripe uses `pi_*`, old charges used `ch_*`, Braintree uses transaction IDs, API uses custom IDs. Is this documented and consistent? Does the `ecommerce_source_filter` handle all cases?

15. **Function naming**: Are function names consistent across modules? Check: `load_data` vs `load_pages` vs `load_stats`. `format_duration` vs `format_ms` vs `format_bytes`. `fmt_num` vs `format_number` (both exist in different files).

16. **Variable naming**: Check for inconsistent naming: `date_range` vs `range` vs `period`. `site_id` vs `site.id`. `user` vs `current_scope.user`.

### D. Error Handling Patterns

17. **Silent error swallowing**: Search for bare `rescue` blocks, `_ ->` catch-alls, `Task.start` fire-and-forget, and `catch` that discard errors. Are any important errors being silently ignored? Especially in: Stripe sync, Braintree sync, search console sync.

18. **mark_error behavior**: `mark_error` no longer changes status to "error" — it keeps "active". Is this documented? Are there any code paths that still assume `mark_error` sets status to "error"?

19. **Integration record fragility**: Integration records have been disappearing/losing state. Review all code paths that create, update, or delete integration records. Are there race conditions?

### E. Test Coverage

20. **Coverage gaps**: Review what's tested and what isn't:
    - Multi-tenancy isolation (12 tests exist — sufficient?)
    - Payment integration CRUD (7 Stripe + 10 Braintree tests)
    - ecommerce_source_filter behavior
    - Sync lock mechanism
    - MRR calculation with different billing intervals
    - Search console data parsing
    - Currency formatting edge cases
    - Invitation flow with accounts

21. **Test quality**: Review existing tests for:
    - Tests that can't fail (assertions on static data)
    - Missing negative tests (what should NOT work)
    - Test setup complexity (excessive fixture creation)

### F. Architecture Concerns

22. **Module size**: `analytics.ex` has 3600+ lines. Should it be split into submodules? Other large files?

23. **settings_live.ex complexity**: The Settings LiveView handles credentials, integrations, sync frequency, clear data, backfill, DNS, site config — all in one file. Should it be split?

24. **health_controller.ex bloat**: Diagnostic endpoints (ecom-diag, fix-ch-schema, click-id-diag) are all in the health controller. Should these be separate controllers?

25. **Separation of concerns**: Is business logic leaking into LiveView modules? Are LiveViews doing data transformation that should be in the analytics layer? Check: mrr_live.ex (has raw ClickHouse queries), search_keywords_live.ex (same).

26. **ClickHouse query consistency**: All ecommerce queries need `ecommerce_source_filter`. All displayed timestamps need `toTimezone`. All revenue displays need `Currency.format`. Are these consistently applied?

### G. Security Review

27. **IDOR protection**: All integration operations use `authorize_integration!`. Are there any event handlers that bypass this?

28. **Multi-tenancy isolation**: Account-scoped queries in admin pages. Are there any queries that leak cross-account data?

29. **Credential handling**: Are all secrets properly encrypted? Are any credentials logged or exposed in error messages?

30. **Diagnostic endpoint security**: `/ecom-diag` and `/fix-ch-schema` use utility token. Is this sufficient? Could they be accessed without auth?

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Category**: Which section (A-G)
3. **Location**: File path and line number(s)
4. **Description**: The code quality issue
5. **Remediation**: Specific fix
6. **Effort**: Low / Medium / High

Conclude with: total tech debt score (1-10), top 10 improvements ranked by effort-to-impact ratio.
