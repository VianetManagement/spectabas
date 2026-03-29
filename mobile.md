# Spectabas Mobile UI/UX Audit Prompt

You are performing a comprehensive mobile-friendliness audit of Spectabas, a web analytics SaaS dashboard built with Phoenix LiveView and Tailwind CSS. The dashboard is used by site owners to monitor traffic, performance, and visitor behavior — many of whom check stats on their phone throughout the day.

## How to Audit

For each section, evaluate the mobile experience at these viewport widths:
- **Small phone**: 320px (iPhone SE, older Android)
- **Standard phone**: 375px (iPhone 14, most modern Android)
- **Large phone**: 428px (iPhone 14 Pro Max)
- **Small tablet**: 768px (iPad Mini)

Review the actual HEEx templates and Tailwind classes in the source code. Check for overflow, truncation, touch target sizes, and readability.

## Current Mobile Architecture

- **Top nav bar**: Full nav hidden below `sm:` breakpoint, replaced by 3 icon buttons (Dashboard, Docs, Account)
- **Dashboard sidebar**: Hidden below `lg:` breakpoint, replaced by two-row mobile header (5 quick-nav icons + horizontal scrolling tab bar with all 22+ pages)
- **Tables**: All wrapped in `overflow-x-auto` for horizontal scrolling
- **Charts**: Chart.js with `responsive: true`, container height `h-48` (192px) on mobile
- **Cards/grids**: Reflow from multi-column to single column via `grid-cols-1 md:grid-cols-2`

---

## Audit Checklist — Review EVERY item below

### A. Navigation & Wayfinding

1. **Top navigation bar**: Review `lib/spectabas_web/components/layouts/root.html.heex`. On phones (<375px), are the 3 mobile icon buttons (Dashboard, Docs, Account) large enough for touch targets (minimum 44x44px per WCAG)? Do they have sufficient spacing? Is the Log Out link accessible on mobile?

2. **Dashboard mobile nav**: Review `lib/spectabas_web/live/dashboard/sidebar_component.ex`. The mobile nav has a quick-access row (5 icons) and a scrollable full nav row. Check:
   - Are the 5 quick-nav choices the right ones? (Currently: Home, Pages, Sources, Visitors, Geo)
   - Is the scrollable nav bar discoverable? Can users tell there are more items to scroll to?
   - Are touch targets in the scrollable bar large enough?
   - Is the active page visually obvious in the scrollable bar?
   - Does the current page title truncate gracefully on narrow screens?

3. **Docs page navigation**: Review `lib/spectabas_web/live/docs_live.ex`. The sidebar is completely hidden on mobile (`hidden lg:flex`). Users must scroll through all docs linearly. Is there a way to jump to sections? Should there be a mobile table-of-contents or collapsible category menu?

4. **Back navigation**: On dashboard sub-pages, is it easy to go back to the main dashboard? Is the "All Sites" link accessible on mobile? Can users navigate between sub-pages without going back to the main dashboard first?

5. **Breadcrumbs/context**: On deep pages (e.g., visitor profile, page transitions), does the user know where they are in the hierarchy? Is there a breadcrumb or clear page title visible without scrolling?

### B. Dashboard Overview (Site Dashboard)

6. **Stat cards**: Review `lib/spectabas_web/live/dashboard/site_live.ex`. The stat cards use `grid grid-cols-2 md:grid-cols-5`. On mobile, 5 stats show as a 2x3 grid (with one orphan). Check:
   - Do the numbers fit without wrapping on 320px screens?
   - Is the comparison percentage ("+12.5%") readable?
   - Are the stat labels truncated or wrapped?

7. **Time period controls**: The preset buttons (Today, 24h, 7d, 30d, 90d, 12m) and custom date picker. On mobile:
   - Do all preset buttons fit in one row or do they wrap?
   - Is the custom date picker usable on mobile? (date inputs, calendar popover)
   - Are the compare toggle and segment filter accessible?

8. **Chart readability**: The timeseries chart is `h-48` (192px) on mobile. Check:
   - Can users read the y-axis values?
   - Are x-axis labels legible without overlap?
   - Are tooltip/hover interactions usable on touch (no hover on mobile)?
   - Is 192px tall enough to convey meaningful data?

9. **Visitor intent cards**: Review the intent breakdown grid (`grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-7`). On mobile (2 cols):
   - Do the intent labels (Buying, Researching, etc.) and counts fit?
   - Are the SVG icons readable at mobile size?
   - Is the click-to-filter interaction obvious?

### C. Data Tables

10. **Horizontal scroll usability**: All tables use `overflow-x-auto`. Check across all table pages:
    - Is there a visual indicator that the table scrolls horizontally? (shadow, fade, scroll indicator)
    - Can users scroll the table without accidentally scrolling the page?
    - On touch devices, is horizontal scrolling smooth and natural?

11. **Visitor Log table**: Review `lib/spectabas_web/live/dashboard/visitor_log_live.ex`. This has 8 columns (Visitor, Intent, Pages, Duration, Location, Device, Source, Entry). On mobile:
    - How much horizontal scrolling is needed?
    - Are the most important columns (Visitor, Pages, Location) visible without scrolling?
    - Should some columns be hidden on mobile?

12. **Pages table**: Review `lib/spectabas_web/live/dashboard/pages_live.ex`. 5 columns including the new Load Time pill. Check:
    - Are page paths (font-mono) readable on mobile?
    - Does the Load Time color pill render correctly at small sizes?
    - Do sortable column headers have adequate touch targets?

13. **Performance tables**: Review `lib/spectabas_web/live/dashboard/performance_live.ex`. Two tables (by Device, Slowest Pages). Check:
    - Are Core Web Vitals cards readable on mobile (LCP, CLS, FID with scores)?
    - Do the vital cards stack properly on mobile (`grid-cols-1 sm:grid-cols-3`)?
    - Are timing values (TTFB, FCP, DOM Ready, Full Load) readable in the grid?

14. **Geography table**: Review `lib/spectabas_web/live/dashboard/geo_live.ex`. Has tabs (Countries, Regions, Cities) + table. Check tab switching and table on mobile.

15. **Network table**: Review `lib/spectabas_web/live/dashboard/network_live.ex`. Has stat cards + ASN table. Check if stat cards are readable on mobile.

### D. Interactive Elements

16. **Form inputs**: Review all pages with form inputs:
    - Transitions page: page path input (`lib/spectabas_web/live/dashboard/transitions_live.ex`)
    - Search page: search term display
    - Settings page: all form fields
    - Segment filter: field/operator/value dropdowns
    - Date picker: from/to date inputs
    Are inputs large enough for mobile? Do they use appropriate mobile keyboard types (`inputmode`)?

17. **Click/tap targets**: Review all clickable elements across dashboard pages:
    - Table row links (page paths, visitor IDs, source domains, ASN numbers)
    - Navigation buttons and tabs
    - Time range preset buttons
    - Sort column headers
    Are all touch targets at least 44x44px (WCAG minimum)?

18. **Modals and popovers**: Check if any modals/popovers are used (e.g., date picker, segment builder, export options). Do they:
    - Fill the mobile viewport appropriately?
    - Have a clear close mechanism?
    - Not get cut off by the viewport?

19. **Pagination**: Pages with pagination (visitor log, exports). Are pagination controls usable on mobile?

### E. Content & Readability

20. **Font sizes**: Review base font sizes across the dashboard. Is `text-xs` (12px) used excessively on mobile? Minimum recommended mobile body text is 14px (text-sm). Check:
    - Table cell text
    - Stat card values and labels
    - Chart axis labels
    - Navigation labels
    - Page descriptions

21. **Text truncation**: Many elements use `truncate` or `max-w-[120px]`. Check:
    - Are URL paths (font-mono, often long) readable or over-truncated on mobile?
    - Are visitor IDs truncated enough to fit?
    - Are referrer domains readable?
    - Can users see the full text somewhere (title attribute, click to expand)?

22. **Number formatting**: Large numbers use `format_number/1` (1.2K, 3.4M). On mobile stat cards, check:
    - Do formatted numbers fit in their containers?
    - Is the unit suffix (K, M) visually connected to the number?
    - Are tabular-nums working for right-aligned columns?

23. **Empty states**: Review empty state messages across pages (no data, no visitors, etc.). Are they helpful and readable on mobile?

### F. Maps & Visualizations

24. **World map**: Review `lib/spectabas_web/live/dashboard/map_live.ex`. The bubble map uses SVG. On mobile:
    - Is the map usable at 192px height?
    - Can users tap on individual bubbles to see country data?
    - Are small countries (e.g., Netherlands, Singapore) visible?
    - Does the map viewport start at a reasonable zoom level?

25. **Cohort retention grid**: Review `lib/spectabas_web/live/dashboard/cohort_live.ex`. The retention grid has many columns (Week 0, +1w, +2w, etc.). On mobile, this is very wide. Is horizontal scrolling adequate?

26. **Journey visualization**: Review `lib/spectabas_web/live/dashboard/journeys_live.ex`. Journey paths are displayed as pill sequences with arrows. Do long journeys wrap or overflow on mobile?

### G. Specific Page Reviews

27. **Your Sites index**: Review `lib/spectabas_web/live/dashboard/index_live.ex`. Site cards on mobile — do they look good in single column? Are the "Add Site" button and stats visible?

28. **Visitor profile**: Review `lib/spectabas_web/live/dashboard/visitor_live.ex`. This has IP details, session history, and event timeline. Is this dense page usable on mobile?

29. **Settings page**: Review `lib/spectabas_web/live/dashboard/settings_live.ex`. Forms with multiple sections (basic info, tracking snippet, GDPR, cross-domain, ecommerce). Are form layouts mobile-friendly?

30. **Campaign UTM builder**: Review `lib/spectabas_web/live/dashboard/campaigns_live.ex`. Has form inputs for building UTM URLs. Are the inputs and generated URL display usable on mobile?

31. **Ecommerce dashboard**: Review `lib/spectabas_web/live/dashboard/ecommerce_live.ex`. Has stat cards + recent orders table. Layout on mobile?

32. **Reports page**: Review `lib/spectabas_web/live/dashboard/reports_live.ex`. Check mobile layout.

33. **Export page**: Review `lib/spectabas_web/live/dashboard/export_live.ex`. Date inputs + download buttons on mobile.

### H. Performance on Mobile

34. **LiveView payload size**: Are LiveView diffs efficient? Large tables with many rows could cause slow updates over mobile connections. Check if any pages load excessive data on mount.

35. **Image/asset loading**: Are there any large images or unoptimized assets that would slow mobile loading?

36. **Touch scroll performance**: Do any elements use heavy CSS (shadows, blur, gradients) that could cause jank during scroll on older phones?

### I. Accessibility on Mobile

37. **Screen reader compatibility**: Are mobile navigation elements properly labeled with `aria-label`? Do icons have accessible names?

38. **Landscape orientation**: Do pages work in landscape mode on phones? Some users rotate their phone to see wide tables better.

39. **Zoom/pinch**: Is the viewport meta tag set correctly? `user-scalable=no` should NOT be set — users need to be able to zoom.

40. **Color contrast**: Do small text elements (text-xs text-gray-400/500) meet WCAG AA contrast ratios (4.5:1 for small text) on mobile? Check stat labels, chart legends, and table headers.

---

## Output Format

For each finding, report:
1. **Severity**: Critical / High / Medium / Low / Informational
2. **Category**: Which section (A-I) above
3. **Location**: File path and approximate line number
4. **Description**: What the mobile UX issue is
5. **Affected viewports**: Which screen sizes are affected
6. **Screenshot description**: What a user would see (since you can't take screenshots)
7. **Remediation**: Specific Tailwind classes or code changes to fix it

Conclude with a prioritized summary of the top 10 mobile UX improvements ranked by impact on user experience.
