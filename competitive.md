# Spectabas Competitive Feature Gap Analysis Prompt

You are analyzing Spectabas against its competitors in the privacy-first web analytics space. The goal is to identify: what features competitors have that we don't, what we have that they don't (our unique advantages), and where the biggest opportunity gaps are.

## Our Product

Spectabas is a multi-tenant, privacy-first web analytics SaaS. Key features as of v1.6.x:

**Core Analytics:** Pageviews, unique visitors, sessions, bounce rate, average duration, time-series charts with Today/24h/7d/30d/90d/12m presets, period comparison, custom date ranges, timezone-aware boundaries.

**Behavior:** Top pages with load time indicators, entry/exit pages, page transitions (came from/went to), site search tracking, real user monitoring (Core Web Vitals, navigation timing).

**Acquisition:** Referrer sources (with self-referral filtering), UTM tracking, multi-channel attribution (first/last touch), campaign builder (UTM URL generator).

**Audience:** Geography (country/region/city drill-down), interactive visitor map, devices (type/browser/OS), network analysis (ISP/datacenter/VPN/Tor/bot %), visitor log with individual profiles, cohort retention grid.

**Intelligence:** Visitor intent detection (buying/researching/comparing/support/returning/browsing/bot), anomaly/insights alerts, visitor journey mapping, browser fingerprinting for dedup.

**Conversions:** Goal tracking (pageview + custom event), funnels, ecommerce (orders/items/revenue).

**Privacy:** GDPR-on mode (fingerprint, no cookies), GDPR-off mode (cookies), IP anonymization, opt-out mechanism, no third-party data sharing.

**Technical:** 8KB tracker, ad-blocker resistant (custom subdomains), first-party data, WebAuthn/passkey 2FA, API with bearer tokens, data export (CSV), bot detection, form abuse detection.

---

## Competitors to Analyze

Research each competitor's PUBLIC feature set (from their marketing sites, docs, and changelogs). For each, identify features they have that Spectabas does NOT.

### 1. Plausible Analytics (plausible.io)
- Open-source, privacy-first, EU-hosted
- Their biggest selling points and unique features
- Their pricing model and target market
- What they do better than us
- What we do better than them

### 2. Fathom Analytics (usefathom.com)
- Privacy-first, simple analytics
- Their unique features and integrations
- Their approach to data accuracy
- Comparison with our feature set

### 3. Matomo (matomo.org)
- Open-source, full-featured Google Analytics alternative
- Self-hosted and cloud options
- Their feature breadth (hundreds of features)
- What enterprise features do they have that we lack?
- What do we do more simply/better?

### 4. PostHog (posthog.com)
- Product analytics + web analytics
- Session replay, feature flags, A/B testing
- Their "all-in-one" approach
- What product analytics features could we learn from?

### 5. Google Analytics 4 (analytics.google.com)
- The incumbent — what features do users expect because GA has them?
- Their machine learning features (predictive audiences, anomaly detection)
- What GA features are we deliberately NOT building (and why)?
- What pain points make users leave GA for privacy-first alternatives?

### 6. Simple Analytics (simpleanalytics.com)
- Ultra-simple, privacy-first
- Their minimalist approach
- Their unique features (tweet tracking, referrer icons)

### 7. Umami (umami.is)
- Open-source, self-hosted
- Their simplicity and developer focus
- Their approach to custom events and goals

---

## Analysis Framework

For each competitor, fill in:

### Feature Comparison Matrix

| Feature Category | Spectabas | Competitor | Gap/Advantage |
|-----------------|-----------|------------|---------------|
| Real-time analytics | Yes | ? | |
| Visitor intent detection | Yes | ? | |
| Core Web Vitals/RUM | Yes | ? | |
| Session replay | No | ? | |
| Heatmaps | No | ? | |
| A/B testing | No | ? | |
| Email reports | No | ? | |
| Slack/Discord integration | No | ? | |
| Custom dashboards | No | ? | |
| Data import from GA | No | ? | |
| Revenue attribution | Partial | ? | |
| Multi-site rollup view | No | ? | |
| White-label/reseller | No | ? | |
| EU data residency | No (US/Ohio) | ? | |
| Shared/public dashboards | No | ? | |
| Annotations on charts | No | ? | |
| ... | | | |

### Key Questions to Answer

1. **What are the top 5 features our competitors have that users most request?** (Check competitor changelogs, GitHub issues, community forums)

2. **What is our strongest differentiator?** (Visitor intent detection? Form abuse detection? Browser fingerprinting? RUM? Something else?)

3. **What features should we deliberately NOT build?** (What doesn't fit our privacy-first, simple-but-powerful positioning?)

4. **What's the minimum viable feature set for enterprise customers?** (SSO, team permissions, audit logs, SLA, data retention policies)

5. **What integrations are most requested?** (WordPress plugin, Shopify app, Slack notifications, Zapier, webhook, API)

6. **Where is the market moving?** (Server-side analytics? Consent management? AI-powered insights? Privacy regulations?)

---

## Output Format

1. **Executive Summary**: 3-5 sentence overview of our competitive position

2. **Feature Gap Matrix**: Sorted by user impact (what gaps matter most to potential customers)

3. **Our Unique Advantages**: Features no competitor matches, ranked by defensibility

4. **High-Priority Gaps**: Features we should build next, ranked by: (a) user demand, (b) competitive necessity, (c) implementation effort

5. **Strategic "Won't Build" List**: Features we deliberately exclude and why

6. **Market Positioning Recommendation**: How we should position against each competitor

7. **Roadmap Suggestions**: Prioritized list of 10 features/improvements for the next 6 months
