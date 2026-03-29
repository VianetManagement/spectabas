# Spectabas RUM Debugging & Fix Prompt

You are debugging why Real User Monitoring metrics (DOM Ready, Full Load, Median Load, P75 Load) are showing as 0 or not appearing on the Performance dashboard, despite visitors being tracked and TTFB/FCP working correctly.

## Symptoms

- TTFB and FCP appear to be collecting (non-zero values on the Performance page)
- DOM Ready, Full Load, Median Load, and P75 Load show as 0ms or empty
- The sites are WordPress/Elementor sites with heavy image loads (load event may take 10-20s)
- Visitor counts are going up, so pageview collection works fine
- The tracker script has been updated multiple times to address this, but the issue persists

## Your Task

1. **Trace the full RUM data pipeline** end-to-end, reading every file involved
2. **Identify exactly why DOM Ready/Full Load/page_load are 0**
3. **Fix the root cause**
4. **Write tests to verify the fix**
5. **Update the changelog**

## Files to Read (in order)

### Layer 1: Client-side collection
Read `priv/static/s.js` — focus on:
- The `collectRUM()` function: what conditions must be true for `page_load`, `dom_complete`, `dom_interactive` to be included?
- The polling schedule: when does `collectRUM()` get called? What is the `force` parameter?
- The send condition: what must be true for the `_rum` event to fire?
- **Critical question**: If `collectRUM(false)` fires at 500ms and `nav.loadEventEnd` is 0 (page hasn't loaded yet), what happens? Does it send without page_load? Does it retry? Or does it set `rumSent=true` and block all future attempts?

### Layer 2: Server-side ingestion
Read `lib/spectabas/events/ingest.ex` — check:
- How does a `_rum` custom event flow through `process/2`?
- Are the properties (`page_load`, `dom_complete`, etc.) preserved through to ClickHouse?
- Read `lib/spectabas/events/event_schema.ex` — does `to_row` preserve the `properties` JSON correctly?

### Layer 3: ClickHouse storage
Read `lib/spectabas/clickhouse.ex` — check:
- The events table schema: is the `properties` column a String?
- Is `JSONEachRow` format preserving the JSON properties correctly?

### Layer 4: Analytics queries
Read `lib/spectabas/analytics.ex` — find ALL rum-related queries:
- `rum_overview`: what columns does it extract from `properties`? Does it use `page_load` or `page_load_ms`? Does it match the key names sent by the tracker?
- `rum_web_vitals`: same check
- `rum_by_page`: same check
- `rum_by_device`: same check
- `rum_vitals_by_page`: same check
- `rum_vitals_summary`: same check
- **Critical question**: Do the `JSONExtractString(properties, 'key')` key names EXACTLY match what the tracker sends in `mapToStrings(perf)`?

### Layer 5: Dashboard display
Read `lib/spectabas_web/live/dashboard/performance_live.ex` — check:
- How does `load_data` call the analytics functions?
- How does the template use the returned data? What keys does it expect (`median_page_load`, `p75_page_load`, etc.)?
- Are the `to_num()` / `to_float()` helpers handling the ClickHouse return values correctly?

## Specific Debugging Steps

### Step A: Verify what the tracker actually sends
Construct a sample `_rum` event payload as it would appear in the `sendEvent("custom", ...)` call. List every key in the `perf` object and its expected value. Then trace what `mapToStrings(perf)` does to it.

### Step B: Verify the ClickHouse query extracts the right keys
For each RUM query, list every `JSONExtractString(properties, 'KEY')` call and verify 'KEY' matches exactly what the tracker sends. Common mismatches:
- `page_load` vs `pageLoad` vs `page_load_ms`
- `dom_complete` vs `domComplete` vs `dom_ready`
- `dom_interactive` vs `domInteractive`

### Step C: Verify the `quantileIf` conditions
The RUM queries use `quantileIf(0.5)(expr, condition)`. The condition checks if the value is > 0. But if the value is an empty string (not "0"), `toFloat64OrZero("")` returns 0, and the condition `> 0` excludes it. This means events sent WITHOUT a `page_load` key will have `JSONExtractString(properties, 'page_load')` return `""`, which becomes `0`, which gets excluded. **This is correct behavior** — but only if some events DO include `page_load`.

### Step D: Check if ANY events have page_load > 0
If you can access ClickHouse (via the health/diag endpoint or directly), check:
```sql
SELECT
  JSONExtractString(properties, 'page_load') AS pl,
  JSONExtractString(properties, 'dom_complete') AS dc,
  JSONExtractString(properties, 'ttfb') AS ttfb,
  count()
FROM events
WHERE event_name = '_rum'
GROUP BY pl, dc, ttfb
ORDER BY count() DESC
LIMIT 20
```
This will show whether any _rum events actually contain page_load values.

### Step E: Verify the `force` parameter logic
In `collectRUM(force)`:
- When `force=false`: sends only if `hasPageLoad` is true (loadEventEnd > 0)
- When `force=true`: sends if just `ttfb > 0`
- The polling at 500ms, 1.5s, 3s, 5s, 8s all call `collectRUM(false)`
- The load event handler calls `collectRUM(false)`
- Only `visibilitychange` and the 10s timeout call `collectRUM(true)`

**Hypothesis**: On heavy WordPress sites, `loadEventEnd` is still 0 at the 8s poll. The 10s `collectRUM(true)` force-sends with just TTFB. But between the load event (which fires at e.g., 12s) and the 10s force timeout, there's a gap. If `rumSent` is set by the force-send at 10s, the load event handler at 12s does nothing (rumSent check at line 1).

**Alternative hypothesis**: The load event handler `window.addEventListener("load", ...)` fires and calls `collectRUM(false)`, but by that time `rumSent` is already true from an earlier force-send.

### Step F: The fundamental design problem
The current design has a tension:
- We want to send early (so data isn't lost if visitor leaves)
- We want to send complete (so page_load is included)
- We can only send once (rumSent flag)

The solution should be one of:
1. **Wait longer before force-sending** — give the load event more time
2. **Send twice** — an early partial event and a late complete event (but this complicates queries)
3. **Only send on load event or visibilitychange** — accept that some very short visits won't have RUM data
4. **Send on load event with a generous timeout** — wait for load event up to 30s, then force-send. The visibilitychange handler catches visitors who leave before 30s.

Option 4 seems best: the load event should be the primary trigger (like all other analytics tools), with visibilitychange as the safety net. The current polling approach is overly complex and has timing bugs.

## Expected Fix

Rewrite the RUM scheduling to:
1. Wait for the `load` event as the primary trigger
2. After load fires, wait 500ms for `loadEventEnd` to populate, then collect
3. If the visitor leaves before load (visibilitychange to hidden), force-send whatever's available
4. Final fallback: 30s timeout force-sends
5. No polling — just event-driven triggers

This eliminates the race condition where early force-sends block later complete sends.

## Testing

After fixing, write tests that verify:
1. The tracker's `collectRUM` function sends `page_load` when `loadEventEnd > 0`
2. The `_rum` event properties include all expected keys
3. The analytics queries extract the correct keys from properties
4. The Performance LiveView correctly displays the values
5. The `quantileIf` conditions work correctly for both present and absent values

## Output

1. Show the exact root cause with file paths and line numbers
2. Show the fix (actual code changes)
3. Show the tests
4. Update the changelog
5. Commit and push
