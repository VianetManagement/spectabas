defmodule SpectabasWeb.DocsLive do
  use SpectabasWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Documentation")
     |> assign(:search, "")
     |> assign(:active_section, "getting-started")
     |> assign(:sections, sections())
     |> assign(:filtered_sections, sections())}
  end

  @impl true
  def handle_event("search", %{"q" => query}, socket) do
    q = String.downcase(String.trim(query))

    filtered =
      if q == "" do
        sections()
      else
        sections()
        |> Enum.map(fn section ->
          matching_items =
            Enum.filter(section.items, fn item ->
              String.contains?(String.downcase(item.title), q) ||
                String.contains?(String.downcase(item.body), q)
            end)

          %{section | items: matching_items}
        end)
        |> Enum.reject(&(&1.items == []))
      end

    {:noreply, socket |> assign(:search, query) |> assign(:filtered_sections, filtered)}
  end

  def handle_event("nav", %{"section" => section}, socket) do
    {:noreply,
     socket
     |> assign(:active_section, section)
     |> push_event("scroll-to", %{id: section})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-56px)]">
      <%!-- Docs sidebar --%>
      <aside class="hidden lg:flex lg:flex-col lg:w-64 bg-white border-r border-gray-200 flex-shrink-0">
        <div class="p-4 border-b border-gray-200">
          <h2 class="text-sm font-semibold text-gray-900">Documentation</h2>
          <div class="mt-2">
            <input
              type="text"
              phx-keyup="search"
              phx-debounce="200"
              name="q"
              value={@search}
              placeholder="Search docs..."
              class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500 py-1.5"
            />
          </div>
        </div>
        <nav class="flex-1 p-3 overflow-y-auto space-y-4">
          <div :for={section <- @filtered_sections}>
            <p class="px-2 text-[10px] font-semibold uppercase tracking-wider text-gray-400 mb-1">
              {section.category}
            </p>
            <button
              :for={item <- section.items}
              phx-click="nav"
              phx-value-section={item.id}
              class={[
                "block w-full text-left px-2 py-1 text-sm rounded-md",
                if(@active_section == item.id,
                  do: "bg-indigo-50 text-indigo-700 font-medium",
                  else: "text-gray-600 hover:bg-gray-50"
                )
              ]}
            >
              {item.title}
            </button>
          </div>
        </nav>
      </aside>

      <%!-- Content --%>
      <main class="flex-1 overflow-y-auto bg-gray-50">
        <div class="max-w-4xl mx-auto px-6 py-8">
          <div :for={section <- @filtered_sections}>
            <div :for={item <- section.items}>
              <article id={item.id} class="mb-12 scroll-mt-8">
                <h2 class="text-2xl font-bold text-gray-900 mb-1">{item.title}</h2>
                <p class="text-xs text-gray-400 uppercase mb-4">{section.category}</p>
                <div class="prose prose-sm prose-indigo max-w-none">
                  <div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
                    {raw(render_markdown(item.body))}
                  </div>
                </div>
              </article>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  # Simple markdown-ish rendering (no external dep)
  defp render_markdown(text) do
    text
    |> String.split("\n\n")
    |> Enum.map(fn block ->
      block = String.trim(block)

      cond do
        String.starts_with?(block, "### ") ->
          "<h4 class=\"text-base font-semibold text-gray-900 mt-6 mb-2\">#{escape(String.trim_leading(block, "### "))}</h4>"

        String.starts_with?(block, "## ") ->
          "<h3 class=\"text-lg font-semibold text-gray-900 mt-6 mb-2\">#{escape(String.trim_leading(block, "## "))}</h3>"

        String.starts_with?(block, "```") ->
          code =
            block
            |> String.trim_leading("```")
            |> String.trim_leading("elixir")
            |> String.trim_leading("javascript")
            |> String.trim_leading("html")
            |> String.trim_leading("bash")
            |> String.trim_leading("json")
            |> String.trim_trailing("```")
            |> String.trim()

          "<pre class=\"bg-gray-900 text-gray-100 rounded-lg p-4 text-xs overflow-x-auto my-3\"><code>#{escape(code)}</code></pre>"

        String.starts_with?(block, "- ") ->
          items =
            block
            |> String.split("\n")
            |> Enum.map(fn line ->
              "<li class=\"ml-4\">#{escape(String.trim_leading(line, "- "))}</li>"
            end)
            |> Enum.join()

          "<ul class=\"list-disc space-y-1 my-2 text-gray-700\">#{items}</ul>"

        String.starts_with?(block, "| ") ->
          render_table(block)

        String.starts_with?(block, "> ") ->
          content =
            block
            |> String.split("\n")
            |> Enum.map(&String.trim_leading(&1, "> "))
            |> Enum.join("<br/>")

          "<div class=\"border-l-4 border-indigo-400 bg-indigo-50 px-4 py-3 my-3 text-sm text-indigo-800\">#{content}</div>"

        true ->
          text = block |> escape() |> render_inline()
          "<p class=\"text-gray-700 my-2 leading-relaxed\">#{text}</p>"
      end
    end)
    |> Enum.join("\n")
  end

  defp render_inline(text) do
    text
    |> String.replace(
      ~r/`([^`]+)`/,
      "<code class=\"bg-gray-100 text-indigo-700 px-1 py-0.5 rounded text-xs font-mono\">\\1</code>"
    )
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
  end

  defp render_table(block) do
    rows = String.split(block, "\n") |> Enum.reject(&String.starts_with?(&1, "|-"))
    [header | body] = rows

    header_cells =
      header |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    header_html =
      Enum.map(
        header_cells,
        &"<th class=\"px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-gray-50\">#{escape(&1)}</th>"
      )
      |> Enum.join()

    body_html =
      Enum.map(body, fn row ->
        cells = row |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        tds =
          Enum.map(cells, &"<td class=\"px-3 py-2 text-sm text-gray-700\">#{escape(&1)}</td>")
          |> Enum.join()

        "<tr class=\"border-t border-gray-100\">#{tds}</tr>"
      end)
      |> Enum.join()

    "<table class=\"min-w-full divide-y divide-gray-200 my-3 rounded-lg overflow-hidden\"><thead><tr>#{header_html}</tr></thead><tbody>#{body_html}</tbody></table>"
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ---- Documentation Content ----

  defp sections do
    [
      %{
        category: "Getting Started",
        items: [
          %{
            id: "getting-started",
            title: "Quick Start Guide",
            body: """
            Welcome to Spectabas, a privacy-first web analytics platform. This guide will help you get up and running in minutes.

            ## Step 1: Create a Site

            Go to **Admin > Sites** and click **New Site**. Enter:
            - **Site Name** — a friendly name (e.g., "My Blog")
            - **Domain** — your analytics subdomain (e.g., `b.example.com`)
            - **Timezone** — your site's timezone for accurate hourly charts
            - **GDPR Mode** — "off" for cookie-based tracking, "on" for fingerprint-based

            ## Step 2: Set Up DNS

            Add a CNAME record pointing your analytics subdomain to `www.spectabas.com`:

            ```
            b.example.com  CNAME  www.spectabas.com
            ```

            If using Cloudflare, keep the proxy **off** (gray cloud) for the analytics subdomain.

            ## Step 3: Install the Tracker

            Add this snippet to your website's `<head>` tag. You'll find the exact code in **Site Settings > Tracking Snippet**.

            ```html
            <script defer data-id="YOUR_PUBLIC_KEY" src="https://b.example.com/assets/v1.js"></script>
            ```

            That's it! Pageviews will start appearing in your dashboard within seconds.

            > **Tip:** The tracker is only 8KB, loads asynchronously, and is designed to avoid ad blockers.
            """
          },
          %{
            id: "tracker-config",
            title: "Tracker Configuration",
            body: """
            The tracking script accepts several `data-` attributes for configuration:

            | Attribute | Values | Default | Description |
            |-----------|--------|---------|-------------|
            | `data-id` | string | required | Your site's public key |
            | `data-gdpr` | "on" / "off" | "on" | GDPR mode (on = fingerprint, off = cookie) |
            | `data-xd` | comma-separated domains | "" | Cross-domain tracking domains |

            ### GDPR Mode

            **GDPR On (default):** Uses a fingerprint (hash of UA + screen + timezone + language) instead of cookies. No consent banner needed. IP addresses are anonymized before storage. Tracking parameters (utm, gclid, etc.) are stripped from URLs.

            **GDPR Off:** Uses a persistent cookie (`_sab`, 2-year lifetime) for more accurate visitor identification. Requires user consent in EU/UK. Full IP addresses stored. UTM parameters preserved in session storage.

            ```html
            <!-- GDPR-compliant (no cookies) -->
            <script defer data-id="KEY" src="https://b.example.com/assets/v1.js"></script>

            <!-- Full tracking with cookies (requires consent) -->
            <script defer data-id="KEY" data-gdpr="off" src="https://b.example.com/assets/v1.js"></script>
            ```

            ### Cross-Domain Tracking

            To track visitors across multiple domains as one session:

            ```html
            <script defer data-id="KEY" data-gdpr="off" data-xd="shop.example.com,blog.example.com" src="https://b.example.com/assets/v1.js"></script>
            ```

            This passes a temporary token via URL parameter (`_sabt`) when visitors click links between your domains. Only works with GDPR mode off.
            """
          },
          %{
            id: "js-api",
            title: "JavaScript API",
            body: """
            The tracker exposes a `window.Spectabas` object for custom tracking:

            ### Track Custom Events

            ```javascript
            // Track a custom event
            Spectabas.track("signup", { plan: "pro" });

            // Track a button click
            document.querySelector("#cta").addEventListener("click", function() {
              Spectabas.track("cta_click", { location: "header" });
            });
            ```

            ### Identify Visitors

            Associate the current visitor with user traits:

            ```javascript
            // After user logs in
            Spectabas.identify({
              email: "user@example.com",
              user_id: "usr_123",
              plan: "enterprise"
            });
            ```

            ### Opt Out

            Let visitors opt out of tracking:

            ```javascript
            // Sets a _sab_optout cookie that prevents all tracking
            Spectabas.optOut();
            ```

            ### Ecommerce Tracking

            ```javascript
            // Track an order
            Spectabas.ecommerce.addOrder({
              order_id: "ORD-123",
              revenue: "99.99",
              currency: "USD"
            });

            // Track individual items
            Spectabas.ecommerce.addItem({
              order_id: "ORD-123",
              sku: "WIDGET-1",
              name: "Blue Widget",
              price: "49.99",
              quantity: "2"
            });
            ```

            ### SPA Support

            The tracker automatically detects single-page app navigation via `history.pushState` and `popstate` events. No additional configuration needed for React, Vue, Next.js, etc.
            """
          }
        ]
      },
      %{
        category: "Dashboard",
        items: [
          %{
            id: "dashboard-overview",
            title: "Dashboard Overview",
            body: """
            The main dashboard shows a summary of your site's performance for the selected time period.

            ### Stat Cards

            The top row shows five key metrics:
            - **Pageviews** — total page loads
            - **Unique Visitors** — distinct visitor count
            - **Sessions** — unique browsing sessions
            - **Bounce Rate** — percentage of single-page sessions with no engagement
            - **Avg Duration** — average time visitors spend on your site

            When **Compare** is enabled (on by default), each card shows the percentage change vs the equivalent previous period. For example, if viewing "7d", it compares to the 7 days before that.

            ### Time Period

            Use the sidebar time controls to select: **24h, 7d, 30d, 90d, or 12m**. The timeseries chart displays hourly data for 24h view and daily data for longer periods. All times are shown in your site's configured timezone.

            ### Visitor Intent

            A unique Spectabas feature. Every visitor is automatically classified by their behavior:
            - **Buying** — visited pricing, checkout, or signup pages
            - **Researching** — viewed 3+ pages or came from paid ads
            - **Comparing** — came from a comparison site (G2, Capterra, etc.)
            - **Support** — visited help, contact, or documentation pages
            - **Returning** — returning visitor with direct access
            - **Browsing** — casual visitor, 1-2 pages
            - **Bot** — detected bot or datacenter traffic

            ### Segment Filters

            Filter all dashboard data by any dimension. Click **Add** in the filter bar and choose a field, operator, and value. For example: `browser is Chrome` or `ip_country is US`.
            """
          },
          %{
            id: "pages",
            title: "Pages",
            body: """
            Shows your top pages ranked by pageviews.

            **Click any page URL** to see its **Page Transitions** — where visitors came from before viewing that page, and where they went afterward.

            ### Columns
            - **Page** — the URL path
            - **Pageviews** — total views
            - **Unique Visitors** — distinct visitors
            - **Avg Duration** — average time on page
            """
          },
          %{
            id: "entry-exit",
            title: "Entry & Exit Pages",
            body: """
            **Entry Pages** show where visitors land when they first arrive at your site. These are your most important landing pages — optimize them for first impressions.

            **Exit Pages** show the last page visitors view before leaving. High exit rates on a page may indicate a problem (unless it's a "thank you" or confirmation page).

            Switch between tabs to see each view.
            """
          },
          %{
            id: "transitions",
            title: "Page Transitions",
            body: """
            For any page on your site, see the navigation flow:

            - **Came from** — pages visitors viewed immediately before this page
            - **Went to** — pages visitors viewed immediately after this page

            Enter a page path (e.g., `/pricing`) and click **Analyze**. Click any page in the results to follow the flow and explore how visitors navigate your site.

            > **Example:** Analyzing `/pricing` might show that 40% came from `/features` and 25% went to `/signup` — telling you your features page effectively drives pricing exploration, and pricing converts to signup.
            """
          },
          %{
            id: "site-search",
            title: "Site Search",
            body: """
            Captures internal search queries automatically from URL parameters. Supports these common parameter names: `q`, `query`, `search`, `s`, `keyword`.

            **No code changes needed** — if your site's search results page uses a URL like `/search?q=widgets`, Spectabas automatically captures "widgets" as a search term.

            This tells you what visitors are looking for on your site, which can inform content creation and navigation improvements.
            """
          },
          %{
            id: "sources",
            title: "Sources",
            body: """
            Shows where your traffic comes from, organized in three tabs:

            - **Referrers** — domains that link to your site (google.com, twitter.com, etc.)
            - **UTM Source** — the `utm_source` parameter from tagged URLs
            - **UTM Medium** — the `utm_medium` parameter (cpc, email, social, etc.)

            **Click any source** to see the visitors from that source in the Visitor Log.

            Your own site's domain and spectabas.com are automatically filtered out to avoid self-referrals.
            """
          },
          %{
            id: "attribution",
            title: "Channel Attribution",
            body: """
            Shows which traffic channels bring visitors, using two attribution models:

            - **First Touch** — credits the channel that first brought the visitor to your site
            - **Last Touch** — credits the most recent channel before the visitor's latest activity

            > **Example:** A visitor first finds you via Google Ads, then returns a week later via an email newsletter. First touch credits Google Ads; last touch credits the newsletter.

            Use this to understand which channels attract new visitors vs which channels drive returning engagement.
            """
          },
          %{
            id: "campaigns",
            title: "Campaigns",
            body: """
            Create and manage UTM-tagged campaign URLs. When you share these tagged links, Spectabas automatically tracks which campaign drove the traffic.

            ### UTM Parameters

            - `utm_source` — where traffic comes from (google, newsletter, facebook)
            - `utm_medium` — the marketing medium (cpc, email, social)
            - `utm_campaign` — the campaign name (spring_sale, product_launch)
            - `utm_term` — paid search keywords (optional)
            - `utm_content` — differentiates similar content (optional)

            ### Example

            ```
            https://example.com/pricing?utm_source=google&utm_medium=cpc&utm_campaign=spring_sale
            ```

            This URL tells Spectabas: "this visitor came from a Google paid ad as part of the spring_sale campaign."
            """
          },
          %{
            id: "geography",
            title: "Geography",
            body: """
            Visitor locations with drill-down navigation:

            1. **Country level** — click a country to see its regions/states
            2. **Region level** — click a region to see cities
            3. **City level** — most granular view

            Countries are shown with full names and ISO codes (e.g., "United States (US)").

            ### Visitor Map

            The map page shows an interactive world map with bubble markers sized by visitor count. Hover over any bubble to see the city name and visitor count.
            """
          },
          %{
            id: "devices",
            title: "Devices",
            body: """
            Three tabs showing your audience's technology:

            - **Device Type** — desktop, smartphone, tablet
            - **Browser** — Chrome, Firefox, Safari, Edge, etc.
            - **OS** — Windows, macOS, Linux, iOS, Android, etc.

            Each is a separate, deduplicated view (no duplicate "smartphone" entries).
            """
          },
          %{
            id: "network",
            title: "Network",
            body: """
            ISP and network analysis showing:

            - **Datacenter %** — traffic from cloud/hosting providers
            - **VPN %** — traffic through VPN services
            - **Tor %** — traffic through the Tor network
            - **Bot %** — detected bot traffic
            - **EU Visitors %** — traffic from EU countries (useful for GDPR awareness)

            **Click any ASN number** to see the visitors from that network in the Visitor Log.

            The ASN table shows each network's organization name, traffic volume, and type badges (DC, VPN, Tor).
            """
          },
          %{
            id: "visitor-log",
            title: "Visitor Log",
            body: """
            Browse individual visitor sessions with:

            - **Pages** — number of pageviews in the session
            - **Duration** — time spent on site
            - **Location** — city, region, country
            - **Device** — browser and OS
            - **Source** — referrer domain
            - **Entry Page** — first page visited

            **Click a visitor ID** to see their full profile. **Click a referrer** to filter by that source. **Click an entry page** to see its transitions.

            The visitor log accepts filters from other pages — when you click an ASN on the Network page or a source on the Sources page, you're taken here with that filter pre-applied.
            """
          },
          %{
            id: "visitor-profile",
            title: "Visitor Profiles",
            body: """
            A comprehensive view of an individual visitor including:

            ### Identity & Device
            Browser, OS, screen size, identification method (cookie vs fingerprint), GDPR mode.

            ### Location & Network
            Country, region, city, timezone, ISP/organization. Badges for datacenter, VPN, or bot traffic.

            ### Acquisition & Behavior
            Original referrer, first and last pages, UTM sources, top pages visited.

            ### IP Cross-Referencing
            Click the IP address to expand a panel showing:
            - Full IP enrichment data (postal code, lat/lon, ASN details)
            - **Other visitors from the same IP** — useful for identifying shared networks, offices, or potential fraud

            ### Session History
            Table of all sessions with entry/exit pages, referrer, and duration.

            ### Event Timeline
            Chronological list of every event (pageviews, custom events, duration pings) with timestamps.
            """
          },
          %{
            id: "cohort",
            title: "Cohort Retention",
            body: """
            A weekly retention grid showing what percentage of visitors return after their first visit.

            - **Rows** = cohort weeks (when visitors first appeared)
            - **Columns** = weeks since first visit (Week 0, +1w, +2w, etc.)
            - **Cells** = percentage of the cohort that returned, color-coded (darker = higher retention)

            > **Example:** If the "Mar 10" row shows 100% at Week 0, 15% at +1w, and 8% at +2w, that means 15% of visitors from that week came back the following week, and 8% came back two weeks later.

            Available in 30-day, 90-day, and 6-month views.
            """
          },
          %{
            id: "realtime",
            title: "Realtime",
            body: """
            Live feed of visitor activity from the last 5 minutes. Shows event type, page, location, device, and timestamp for each event as it happens.

            The dashboard header also shows a live visitor count with a green pulse indicator.
            """
          }
        ]
      },
      %{
        category: "REST API",
        items: [
          %{
            id: "api-auth",
            title: "API Authentication",
            body: """
            All API requests require a Bearer token in the Authorization header.

            ### Getting an API Key

            Go to **Account > Settings** and generate an API key. The key starts with `sab_live_`.

            ### Making Requests

            ```bash
            curl -H "Authorization: Bearer sab_live_YOUR_KEY" \\
              https://www.spectabas.com/api/v1/sites/1/stats
            ```

            ### Error Responses

            | Status | Meaning |
            |--------|---------|
            | 401 | Invalid or missing API key |
            | 403 | API key doesn't have access to this site |
            | 404 | Site not found |
            """
          },
          %{
            id: "api-stats",
            title: "API: Overview Stats",
            body: """
            `GET /api/v1/sites/:site_id/stats`

            Returns pageviews, unique visitors, sessions, bounce rate, and average duration.

            ### Parameters

            | Param | Type | Default | Description |
            |-------|------|---------|-------------|
            | `period` | string | "7d" | Time period: "day", "week", "month" |

            ### Example Response

            ```json
            {
              "data": {
                "pageviews": "142",
                "unique_visitors": "89",
                "total_sessions": "95",
                "bounce_rate": "45.2",
                "avg_duration": "124"
              }
            }
            ```

            > **Note:** ClickHouse returns all values as strings. Parse them as numbers in your client code.
            """
          },
          %{
            id: "api-pages",
            title: "API: Top Pages",
            body: """
            `GET /api/v1/sites/:site_id/pages`

            Returns top pages ranked by pageviews.

            ```json
            {
              "data": [
                {"url_path": "/", "pageviews": "50", "unique_visitors": "42", "avg_duration": "30"},
                {"url_path": "/pricing", "pageviews": "25", "unique_visitors": "22", "avg_duration": "90"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-sources",
            title: "API: Sources",
            body: """
            `GET /api/v1/sites/:site_id/sources`

            Returns top traffic sources.

            ```json
            {
              "data": [
                {"referrer_domain": "google.com", "utm_source": "", "utm_medium": "", "pageviews": "30", "sessions": "25"},
                {"referrer_domain": "twitter.com", "utm_source": "", "utm_medium": "", "pageviews": "12", "sessions": "10"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-countries",
            title: "API: Countries",
            body: """
            `GET /api/v1/sites/:site_id/countries`

            Returns visitor locations with country, region, and city.

            ```json
            {
              "data": [
                {"ip_country": "US", "ip_region_name": "California", "ip_city": "San Francisco", "pageviews": "20", "unique_visitors": "15"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-devices",
            title: "API: Devices",
            body: """
            `GET /api/v1/sites/:site_id/devices`

            Returns device type, browser, and OS breakdown.

            ```json
            {
              "data": [
                {"device_type": "desktop", "browser": "Chrome", "os": "macOS", "pageviews": "80", "unique_visitors": "60"}
              ]
            }
            ```
            """
          },
          %{
            id: "api-realtime",
            title: "API: Realtime",
            body: """
            `GET /api/v1/sites/:site_id/realtime`

            Returns the number of active visitors in the last 5 minutes.

            ```json
            {
              "data": {
                "active_visitors": 3
              }
            }
            ```
            """
          }
        ]
      },
      %{
        category: "Administration",
        items: [
          %{
            id: "user-roles",
            title: "User Roles & Permissions",
            body: """
            Spectabas has four user roles:

            | Role | Access |
            |------|--------|
            | **Superadmin** | Full access. Manage users, sites, billing, all settings. Required for 2FA setup. |
            | **Admin** | Manage sites and settings. Add/remove sites, configure tracking, invite users. |
            | **Analyst** | View all analytics data. Dashboards, reports, visitor logs, exports. Cannot change settings. |
            | **Viewer** | Read-only dashboard access for permitted sites only. |

            ### Inviting Users

            Go to **Admin > Users** and click **Invite User**. Enter their email and select a role. They'll receive an email with a link to set up their account (link expires in 48 hours).

            You can **Resend** an invitation (which revokes the old link and sends a new one) or **Revoke** it entirely.
            """
          },
          %{
            id: "site-settings",
            title: "Site Settings",
            body: """
            Each site has these configurable options:

            - **Name** — display name in the dashboard
            - **Domain** — the analytics subdomain (e.g., `b.example.com`)
            - **Timezone** — used for hourly chart display (e.g., `America/New_York`)
            - **GDPR Mode** — "on" (fingerprint, no cookies) or "off" (cookies, more accurate)
            - **Cookie Domain** — for cross-subdomain cookie sharing
            - **Cross-Domain Tracking** — enable and list domains for cross-site visitor tracking
            - **IP Blocklist** — block specific IPs from being tracked
            - **Ecommerce** — enable ecommerce tracking with currency setting
            """
          },
          %{
            id: "goals-funnels",
            title: "Goals & Funnels",
            body: """
            ### Goals

            Track specific visitor actions:
            - **Pageview goals** — triggered when a visitor views a specific page (supports wildcards: `/blog/*`)
            - **Custom event goals** — triggered when your JavaScript calls `Spectabas.track("event_name")`

            ### Funnels

            Define multi-step conversion paths to see where visitors drop off. Each step can be a pageview (URL path match) or a custom event.

            > **Example funnel:** Homepage → Features → Pricing → Signup. If 1000 visitors start at Homepage but only 50 reach Signup, you can see exactly where the drop-off happens.
            """
          },
          %{
            id: "api-keys-setup",
            title: "API Keys",
            body: """
            Generate API keys from **Account > Settings > API Keys**.

            1. Click **+ New Key**
            2. Enter a name (e.g., "Production", "CI/CD")
            3. Copy the key immediately — it's only shown once
            4. Use the key in the `Authorization: Bearer <key>` header

            Keys can be revoked at any time. Revoked keys stop working immediately.

            > **Security:** Only the SHA-256 hash of the key is stored. The plaintext is never saved.
            """
          },
          %{
            id: "two-factor",
            title: "Two-Factor Authentication",
            body: """
            Spectabas supports two types of 2FA:

            ### TOTP (Authenticator App)

            Use any TOTP-compatible app (Google Authenticator, Authy, 1Password, Bitwarden):
            1. Go to **Account > Settings > Two-Factor Authentication**
            2. Click **Set Up 2FA**
            3. Scan the QR code with your authenticator app
            4. Enter the 6-digit code to confirm

            ### Passkeys / Security Keys

            Use a passkey (Bitwarden, 1Password, YubiKey, Touch ID, Windows Hello):
            1. Go to **Account > Settings > Security Keys (Passkeys)**
            2. Click **+ Add Key**
            3. Follow your browser's prompt to create or select a passkey
            4. Name the key for identification

            You can register multiple security keys. Each can be removed individually.

            ### Admin: Force 2FA

            Administrators can require 2FA for specific users:
            1. Go to **Admin > Users**
            2. Click the **Optional/Required** toggle in the Force 2FA column
            3. Users with "Required" must set up 2FA before accessing the dashboard
            """
          },
          %{
            id: "visitor-intent",
            title: "Visitor Intent Detection",
            body: """
            Spectabas automatically classifies every visitor by their behavior:

            | Intent | How it's detected |
            |--------|------------------|
            | Buying | Visited /pricing, /checkout, /signup, or came from paid ad |
            | Researching | Viewed 3+ pages, or paid traffic on content pages |
            | Comparing | Came from G2, Capterra, TrustRadius, ProductHunt |
            | Support | Visited /help, /contact, /docs, /faq |
            | Returning | Prior sessions, direct access |
            | Browsing | 1-2 pages, no conversion signals |
            | Bot | Datacenter IP, headless browser, no interaction |

            ### Using Intent Data

            - **Dashboard** — intent breakdown card shows visitor counts per category
            - **Click any intent** to see those visitors in the Visitor Log
            - **Segment filter** — use `visitor_intent is buying` to filter any report
            - **Visitor profiles** — intent pill shown on each visitor
            """
          },
          %{
            id: "browser-fingerprinting",
            title: "Browser Fingerprinting",
            body: """
            Spectabas generates a unique browser fingerprint for every visitor using canvas rendering, WebGL renderer strings, AudioContext output, and 15+ additional browser signals including installed fonts, screen properties, timezone, language, and hardware concurrency.

            ### How It Works

            The fingerprint is a stable hash that **survives cookie clearing, incognito mode, and VPN changes**. Because it is derived from browser and hardware characteristics rather than stored state, it persists across sessions even when visitors take steps to reset their identity.

            ### GDPR Mode Integration

            When GDPR mode is enabled (`data-gdpr="on"`), the browser fingerprint is used as the visitor ID instead of a cookie. This means accurate visitor deduplication without storing any cookies or requiring a consent banner.

            ### Visitor Profiles

            Each visitor profile includes a **Same Browser Fingerprint** section that lists other visitor IDs sharing the same fingerprint. This reveals alt accounts, shared devices, or attempts to create multiple identities.

            ### Use Cases

            - **Alt account detection** — identify users operating multiple accounts
            - **Ban evasion** — detect banned users returning under new visitor IDs
            - **Fraud detection** — correlate suspicious activity across sessions
            - **Spam correlation** — link spam submissions to a single browser

            No configuration is needed. Browser fingerprinting is automatic for all tracked sites.
            """
          },
          %{
            id: "form-abuse-detection",
            title: "Form Abuse Detection",
            body: """
            The Spectabas tracker automatically monitors form interactions on your site and detects suspicious submission patterns without any configuration.

            ### Detected Patterns

            The tracker watches for the following abuse signals:

            - **Rapid submission** — form submitted less than 2 seconds after page load
            - **Repeated submissions** — more than 3 form submissions on a single page
            - **Excessive pasting** — more than 3 paste events detected in form fields
            - **Click flooding** — more than 10 rapid clicks in a short time window

            ### Automatic Event Firing

            When suspicious patterns are detected, the tracker automatically fires a `_form_abuse` custom event. This event appears in your dashboard alongside other custom events and includes properties describing which signals were triggered.

            ### No Configuration Required

            Form abuse detection works on any site running the Spectabas tracker. There are no data attributes to set and no JavaScript API calls to make. The tracker handles all monitoring and event firing automatically.

            ### Combined with Fingerprinting

            Form abuse events are tagged with the visitor's browser fingerprint. This means you can correlate abuse across sessions, detect serial spammers who clear cookies between submissions, and link form abuse to specific visitor profiles for investigation.

            > **Example:** A spammer submits your contact form 5 times in 10 seconds, clears cookies, and tries again. Spectabas fires `_form_abuse` events for both sessions, and the browser fingerprint links them to the same person.
            """
          }
        ]
      }
    ]
  end
end
