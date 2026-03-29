# Spectabas Code Quality & Maintainability Audit Prompt

You are auditing the Spectabas codebase for code quality, maintainability, and technical debt. The project has grown rapidly from a simple tracker to a 23+ page analytics dashboard. Rapid iteration leaves patterns that should be consolidated, dead code that should be removed, and conventions that should be enforced.

---

## Audit Checklist

### A. Code Duplication

1. **range_to_atom duplication**: The pattern `defp range_to_atom("24h"), do: :day` is duplicated in 16+ dashboard LiveView files. Review all instances — are they all identical? Should this be a shared function in a helper module or the SidebarComponent?

2. **to_num/to_float duplication**: These ClickHouse-string-to-number conversion helpers are defined in: performance_live.ex, site_live.ex, index_live.ex, pages_live.ex, transitions_live.ex, and likely more. Should they be in a shared module?

3. **Date range construction duplication**: Many pages construct date ranges from presets in slightly different ways. Compare: site_live.ex (Date-based with timezone), sub-pages (atom-based via range_to_atom), API controller (UTC DateTime), index_live (Analytics.period_to_date_range). Should there be one canonical way?

4. **Authorization check pattern**: Every LiveView mount does `unless Accounts.can_access_site?(user, site)`. Is this consistently implemented? Are there any pages that skip it? Could this be a shared on_mount hook?

5. **Table rendering patterns**: Review table HTML across pages_live, visitor_log_live, entry_exit_live, geo_live, network_live, sources_live. Is the table markup consistent? Could there be a shared table component?

### B. Dead Code & Unused Features

6. **Unused functions**: Search for functions defined but never called. Check: public functions in analytics.ex, helper functions in LiveView modules, test fixture functions.

7. **Unreachable code paths**: Review pattern matches and case/cond branches that can never be reached. Check: range_to_atom catch-all clauses, error handling branches that are structurally impossible.

8. **Commented-out code**: Search for commented code blocks that should be removed.

9. **Unused imports/aliases**: Check for `alias` or `import` statements that aren't used in the module.

10. **Stale configuration**: Review config files for settings that reference removed features or unused environment variables.

### C. Naming Conventions

11. **Consistent column naming**: ClickHouse columns use: `ip_country`, `duration_s`, `referrer_url`, `browser_fingerprint`. Do all queries reference the correct column names? Have any column name mismatches been introduced? (This has caused multiple bugs.)

12. **Event type/name conventions**: Events use `event_type` ("pageview", "custom", "duration") and `event_name` ("_rum", "_cwv", "_form_abuse", "signup"). Is the naming consistent? Are internal events (prefixed with `_`) documented?

13. **Function naming**: Are function names consistent across modules? Check: `load_data` vs `load_pages` vs `load_stats` patterns. `format_duration` vs `format_ms` vs `format_bytes`.

14. **Variable naming**: Check for inconsistent naming: `date_range` vs `range` vs `period`. `site_id` vs `site.id`. `user` vs `current_scope.user`.

### D. Error Handling Patterns

15. **Inconsistent error handling**: Compare error handling across analytics functions. Some return `{:ok, data}` / `{:error, reason}`, some use `case` with fallback, some use `with`. Is there a consistent pattern?

16. **Silent error swallowing**: Search for bare `rescue` blocks, `_ ->` catch-alls, and `catch` that discard errors. Are any important errors being silently ignored?

17. **Error messages**: Are error messages user-friendly in LiveView flash messages? Are they developer-friendly in logs?

### E. Test Coverage

18. **Coverage gaps**: Review what's tested and what isn't:
    - Analytics queries (requires ClickHouse — currently untested)
    - Ingest pipeline (partially tested)
    - LiveView interactions (page loads tested, but events/state changes?)
    - API endpoints
    - Edge cases in payload validation
    - Timezone handling
    - Error paths

19. **Test quality**: Review existing tests for:
    - Tests that can't fail (assertions on static data)
    - Missing negative tests (what should NOT work)
    - Flaky tests (time-dependent, order-dependent)
    - Test setup complexity (excessive fixture creation)

20. **Missing integration tests**: Are there end-to-end flows that should be tested?
    - Event collection → ingest → ClickHouse storage → dashboard display
    - User signup → site creation → tracker installation → first pageview
    - Invitation → acceptance → site access

### F. Architecture Concerns

21. **Module size**: Identify oversized modules. `analytics.ex` likely has 1000+ lines of query functions. Should it be split into submodules (Analytics.Pages, Analytics.Sources, Analytics.RUM)?

22. **Separation of concerns**: Is business logic leaking into LiveView modules? Are LiveViews doing data transformation that should be in the analytics layer?

23. **Configuration management**: Are environment variables documented? Are defaults safe? Is there validation on startup for required config?

24. **Dependency management**: Are all dependencies pinned to specific versions? Are there any deprecated dependencies? When was the last `mix deps.update`?

### G. Documentation Quality

25. **CLAUDE.md accuracy**: Does CLAUDE.md reflect the current state of the codebase? Are the architecture diagrams, feature lists, and important patterns still accurate?

26. **Inline documentation**: Are complex functions documented with `@doc`? Are module-level `@moduledoc` present? Are tricky algorithms commented?

27. **API documentation**: Is the REST API fully documented in the docs page? Do the endpoint descriptions match the actual implementations?

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Category**: Which section (A-G)
3. **Location**: File path and line number(s)
4. **Description**: The code quality issue
5. **Remediation**: Specific refactoring with code examples
6. **Effort**: Low / Medium / High (estimated time to fix)

Conclude with: total tech debt score (1-10), top 10 improvements ranked by effort-to-impact ratio, and a suggested refactoring priority list.
