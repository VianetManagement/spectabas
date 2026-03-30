defmodule SpectabasWeb.Admin.CompetitiveLive do
  @moduledoc "Competitive feature gap analysis — internal strategy reference."

  use SpectabasWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Competitive Analysis")
     |> assign(:active_section, "summary")}
  end

  @impl true
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
      <%!-- Sidebar --%>
      <aside class="hidden lg:flex lg:flex-col lg:w-64 bg-white border-r border-gray-200 flex-shrink-0">
        <div class="p-4 border-b border-gray-200">
          <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
            &larr; Admin
          </.link>
          <h2 class="text-sm font-semibold text-gray-900 mt-2">Competitive Analysis</h2>
          <p class="text-xs text-gray-500 mt-0.5">Updated March 2026</p>
        </div>
        <nav class="flex-1 p-3 overflow-y-auto space-y-1">
          <button
            :for={{id, label} <- nav_items()}
            phx-click="nav"
            phx-value-section={id}
            class={[
              "block w-full text-left px-2 py-1 text-sm rounded-md",
              if(@active_section == id,
                do: "bg-indigo-50 text-indigo-700 font-medium",
                else: "text-gray-600 hover:bg-gray-50"
              )
            ]}
          >
            {label}
          </button>
        </nav>
      </aside>

      <%!-- Content --%>
      <main class="flex-1 overflow-y-auto bg-gray-50">
        <div class="max-w-5xl mx-auto px-6 py-8">
          <%!-- Mobile nav --%>
          <div class="lg:hidden mb-6">
            <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
              &larr; Admin
            </.link>
            <select
              phx-change="nav"
              name="section"
              class="mt-2 block w-full rounded-lg border-gray-300 text-sm py-2.5"
            >
              <option :for={{id, label} <- nav_items()} value={id} selected={@active_section == id}>
                {label}
              </option>
            </select>
          </div>

          <div :for={section <- sections()}>
            <article id={section.id} class="mb-12 scroll-mt-8">
              <h2 class="text-2xl font-bold text-gray-900 mb-4">{section.title}</h2>
              <div class="bg-white rounded-lg shadow-sm border border-gray-200 p-6">
                {raw(render_content(section.body))}
              </div>
            </article>
          </div>
        </div>
      </main>
    </div>
    """
  end

  defp nav_items do
    Enum.map(sections(), fn s -> {s.id, s.title} end)
  end

  # Simple markdown-ish renderer (reuses patterns from DocsLive)
  defp render_content(text) do
    text
    |> String.split("\n\n")
    |> Enum.map(fn block ->
      block = String.trim(block)

      cond do
        String.starts_with?(block, "### ") ->
          "<h4 class=\"text-base font-semibold text-gray-900 mt-6 mb-2\">#{esc(String.trim_leading(block, "### ")) |> inline()}</h4>"

        String.starts_with?(block, "| ") ->
          render_table(block)

        String.starts_with?(block, "- ") ->
          items =
            block
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.map(fn line ->
              "<li class=\"ml-4\">#{esc(String.trim_leading(line, "- ")) |> inline()}</li>"
            end)
            |> Enum.join()

          "<ul class=\"list-disc space-y-1 my-2 text-gray-700\">#{items}</ul>"

        block == "---" ->
          "<hr class=\"my-6 border-gray-200\" />"

        true ->
          "<p class=\"text-gray-700 my-2 leading-relaxed\">#{esc(block) |> inline()}</p>"
      end
    end)
    |> Enum.join("\n")
  end

  defp render_table(block) do
    rows =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn row -> String.starts_with?(row, "|-") || row == "" end)

    case rows do
      [header | body] ->
        header_cells =
          header |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

        header_html =
          Enum.map(header_cells, fn c ->
            "<th class=\"px-3 py-2 text-left text-xs font-medium text-gray-500 uppercase bg-gray-50\">#{esc(c) |> inline()}</th>"
          end)
          |> Enum.join()

        body_html =
          Enum.map(body, fn row ->
            cells =
              row |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

            tds =
              Enum.map(cells, fn c ->
                "<td class=\"px-3 py-2 text-sm text-gray-700\">#{esc(c) |> inline()}</td>"
              end)
              |> Enum.join()

            "<tr class=\"border-t border-gray-100\">#{tds}</tr>"
          end)
          |> Enum.join()

        "<div class=\"overflow-x-auto my-3\"><table class=\"min-w-full divide-y divide-gray-200 rounded-lg overflow-hidden\"><thead><tr>#{header_html}</tr></thead><tbody>#{body_html}</tbody></table></div>"

      _ ->
        ""
    end
  end

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp inline(text) do
    text
    |> String.replace(
      ~r/`([^`]+)`/,
      "<code class=\"bg-gray-100 text-indigo-700 px-1 py-0.5 rounded text-xs font-mono\">\\1</code>"
    )
    |> String.replace(~r/\*\*([^*]+)\*\*/, "<strong>\\1</strong>")
  end

  defp sections do
    [
      %{
        id: "summary",
        title: "Executive Summary",
        body: """
        Spectabas occupies a strong middle ground in the privacy-first analytics market: significantly more analytical depth than simple alternatives (Plausible, Fathom, Simple Analytics, Umami) while maintaining genuine privacy compliance that GA4, Matomo, and PostHog cannot match without extensive configuration.

        **Unique differentiators** that no single competitor replicates: visitor intent detection, Core Web Vitals/RUM, page transitions, network/datacenter analysis, form abuse detection, and ad-blocker-resistant custom subdomain tracking.

        **Key gaps** in three areas: ecosystem/integrations (no WordPress plugin, no Slack/webhook notifications, no GA data import), collaboration features (no email reports, no chart annotations), and enterprise readiness (no SSO/SAML, US-only hosting, no self-hosted option).

        Closing the integration and collaboration gaps removes the most common objections from prospects evaluating against Plausible or Fathom.
        """
      },
      %{
        id: "unique-advantages",
        title: "Our Unique Advantages",
        body: """
        ### Tier 1: No competitor has this

        - **Visitor Intent Detection** — automatic classification as buying/researching/comparing/support/returning/browsing/bot. Genuinely novel and difficult to replicate. Transforms "what happened" into "why they came."
        - **Page Transition Analysis** — came from / went to navigation flow. GA4 has path exploration but it's unusable. Matomo has Transitions as a paid plugin.
        - **Network Intelligence** — ISP/datacenter/VPN/Tor/bot % by ASN. No privacy-first competitor offers this.
        - **Form Abuse Detection** — identifying spam and abuse patterns. Unique in this space.
        - **IP Cross-referencing** — other visitors from the same IP. Useful for B2B company identification.

        ### Tier 2: Very few competitors match

        - **Core Web Vitals / RUM** — only Matomo (via plugin) and PostHog offer similar. No other privacy tool does.
        - **Ad-blocker Resistant Subdomains** — CNAME-based custom subdomain is more robust than competitors' proxy approaches.
        - **Visitor Journey Mapping** — only PostHog (session replay) and GA4 (path exploration) are comparable.
        - **Cohort Retention Grid** — only PostHog and GA4 have this natively.
        - **Multi-channel Attribution** — among privacy tools, only Spectabas and Matomo offer real attribution.
        """
      },
      %{
        id: "gaps",
        title: "Feature Gap Matrix",
        body: """
        Features competitors have that we don't, sorted by user impact:

        | Priority | Feature | Who Has It | Effort |
        |----------|---------|------------|--------|
        | **P1** | Email Reports (weekly/monthly) | Plausible, Fathom, Matomo, GA4, Simple Analytics | Low |
        | **P1** | WordPress Plugin | Plausible, Fathom, Matomo, GA4, Simple Analytics, Umami | Medium |
        | **P1** | Embeddable Dashboard (iframe) | Plausible, Fathom, Matomo, PostHog, Simple Analytics, Umami | Low |
        | **P2** | Webhook/Slack Notifications | Matomo, PostHog, Simple Analytics | Low-Medium |
        | **P2** | GA Data Import | Plausible, Matomo, Simple Analytics | Medium |
        | **P2** | EU Data Residency | Plausible, Fathom, Matomo, PostHog, Simple Analytics, Umami | High |
        | **P2** | Chart Annotations | Matomo, Simple Analytics | Low |
        | **P3** | Multi-site Rollup | Matomo, GA4 | Medium |
        | **P3** | Session Replay | Matomo, PostHog | Won't build |
        | **P3** | Heatmaps | Matomo, PostHog | Won't build |
        | **P3** | A/B Testing | Matomo, PostHog, GA4 | Won't build |
        | **P3** | Custom Dashboard Builder | Matomo, PostHog, GA4 | High |
        | **P4** | SSO/SAML | Plausible, Matomo, PostHog, GA4 | High |
        | **P4** | Self-hosted Option | Plausible, Matomo, PostHog, Umami | Very High |
        """
      },
      %{
        id: "wont-build",
        title: "Strategic Won't Build",
        body: """
        Features we deliberately exclude and why:

        - **Session Replay** — fundamentally incompatible with privacy-first positioning. Recording sessions captures PII by nature. Let PostHog/Matomo own this.
        - **Heatmaps / Click Maps** — same privacy concerns. Requires DOM capture that reveals personal data.
        - **Predictive Audiences / ML Segmentation** — GA4's territory, requires massive data scale, nudges toward surveillance profiling.
        - **Mobile App SDKs** — different product entirely. Would dilute focus. Dominated by Firebase, Mixpanel, Amplitude.
        - **Built-in Consent Management** — separate product category (Cookiebot, OneTrust). Our privacy-by-design means consent often unnecessary.
        - **Cross-device Tracking** — requires persistent user identification across devices, conflicts with privacy principles.
        - **Full Product Analytics** — PostHog's territory. Combining web + product analytics leads to complexity bloat.
        - **Advertising Platform Integration** — GA4's moat. We serve customers who left GA to avoid ad-tech. Building toward ad platforms betrays our positioning.
        """
      },
      %{
        id: "positioning",
        title: "Positioning vs. Competitors",
        body: """
        ### vs. Plausible
        **Key message:** "Outgrow Plausible without outgrowing your privacy principles."

        We offer visitor intent, page transitions, RUM, network analysis, cohort retention, attribution, journey mapping, and ecommerce — none of which Plausible has. Plausible is a dashboard; Spectabas is an analytics platform.

        ### vs. Fathom
        **Key message:** "When simple analytics aren't enough, but GA4 is too much."

        Fathom deliberately limits features. Spectabas offers the same privacy guarantees with 10x the analytical depth.

        ### vs. Matomo
        **Key message:** "Modern analytics intelligence without the Matomo maintenance burden."

        Matomo is bloated, slow, requires server resources for self-hosting. Spectabas is modern, fast (ClickHouse-backed), with intelligence features Matomo lacks.

        ### vs. PostHog
        **Key message:** "Purpose-built web analytics with intelligence PostHog can't match."

        PostHog is product analytics that added web analytics. Our web analytics depth (intent, network, attribution) is purpose-built. PostHog doesn't prioritize privacy.

        ### vs. GA4
        **Key message:** "The analytics Google Analytics should have been — private, fast, intelligent."

        Every customer is someone frustrated by GA4's complexity, privacy concerns, data sampling, or Google's data harvesting.

        ### vs. Umami
        **Key message:** "Graduate from Umami to real analytics."

        Umami lacks attribution, funnels, ecommerce, RUM, visitor profiles, intent detection. Spectabas is the professional upgrade.
        """
      },
      %{
        id: "roadmap",
        title: "6-Month Roadmap",
        body: """
        ### Month 1-2: Close the Collaboration Gap

        - **Email Reports** — weekly/monthly digest per site. Notification infrastructure exists. Most impactful single feature to close gap with Plausible/Fathom.
        - **Embeddable Dashboard** — add `?embed=true` param that strips nav chrome. Provide iframe snippet in settings. Low effort, high value for agencies.
        - **Chart Annotations** — Postgres table, Chart.js vertical lines. Mark deploys, campaigns, incidents.

        ### Month 2-3: Close the Ecosystem Gap

        - **WordPress Plugin** — snippet installer + settings page for public key. Publish to wordpress.org. Removes biggest adoption barrier.
        - **Webhook Notifications** — webhook URL in site settings, fire on traffic spikes, goal completions, new referrer sources. Enables Slack/Discord/Zapier without building each.
        - **GA Data Import** — CSV import of pageviews/sessions/sources by day. Reduces switching friction dramatically.

        ### Month 3-4: Strengthen Unique Advantages

        - **Visitor Intelligence Dashboard** — dedicated section consolidating intent/network/journey features. Add company identification via reverse DNS/ASN. Intent trends over time. Weekly intelligence briefs.
        - **Shopify App** — auto-install tracker, map Shopify events to ecommerce tracking. Makes ecommerce turnkey.

        ### Month 5-6: Scale and Enterprise

        - **Multi-site Rollup Dashboard** — aggregate analytics across sites. Essential for agencies.
        - **EU Hosting Option** — second Render region or Hetzner-based ClickHouse. Choose data residency at site creation.
        """
      },
      %{
        id: "market",
        title: "Market Trends",
        body: """
        - **Stricter privacy regulation** — GDPR enforcement increasing, US state laws multiplying. Strong tailwind for privacy-first tools.
        - **Cookie deprecation** — our cookieless fingerprint mode is already ready for a post-cookie world.
        - **Server-side/edge analytics** — Cloudflare, Vercel pushing edge analytics. Our custom subdomain approach is ahead of this trend.
        - **AI-powered insights** — our anomaly detection and intent classification position us well for the "AI analytics" narrative.
        - **Tool consolidation** — resist this. Stay focused on web analytics excellence rather than becoming an all-in-one platform.
        - **Enterprise privacy demands** — SOC 2, HIPAA, GDPR are table stakes for enterprise sales. We need compliance documentation.
        """
      }
    ]
  end
end
