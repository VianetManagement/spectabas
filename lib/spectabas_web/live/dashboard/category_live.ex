defmodule SpectabasWeb.Dashboard.CategoryLive do
  use SpectabasWeb, :live_view

  @moduledoc "Landing pages for dashboard categories — hub with page descriptions and quick links."

  alias Spectabas.{Accounts, Sites}
  import SpectabasWeb.Dashboard.SidebarComponent

  @categories %{
    "overview" => %{
      title: "Overview",
      description: "Your site at a glance — key metrics, visitor trends, and live activity.",
      color: "indigo",
      active: "overview-landing",
      pages: [
        %{
          key: "overview",
          path: "",
          label: "Dashboard",
          desc: "Time-series chart of pageviews and visitors, stat cards with period comparison, segment filters, and visitor intent breakdown. Your daily starting point."
        },
        %{
          key: "insights",
          path: "insights",
          label: "Insights",
          desc: "Automated highlights and anomalies detected in your data. Surfaces notable changes in traffic, sources, or conversions without manual digging."
        },
        %{
          key: "journeys",
          path: "journeys",
          label: "Journeys",
          desc: "Visitor navigation flows — see how people move through your site from entry to exit. Sankey-style visualization of the most common page transitions."
        },
        %{
          key: "realtime",
          path: "realtime",
          label: "Realtime",
          desc: "Live visitors on your site right now. See their current page, location, device, traffic source, and ad platform. Updates every 5 seconds."
        }
      ]
    },
    "behavior" => %{
      title: "Behavior",
      description: "How visitors interact with your content — what they view, where they go, and how they engage.",
      color: "blue",
      active: "behavior-landing",
      pages: [
        %{
          key: "pages",
          path: "pages",
          label: "Pages",
          desc: "Top pages ranked by pageviews, unique visitors, and bounce rate. Click any page to see its row evolution sparkline showing trends over time."
        },
        %{
          key: "entry-exit",
          path: "entry-exit",
          label: "Entry / Exit",
          desc: "Where visitors land (entry pages) and where they leave (exit pages). High exit rates on key pages may indicate content or UX issues."
        },
        %{
          key: "transitions",
          path: "transitions",
          label: "Page Transitions",
          desc: "For any page, see where visitors came from and where they went next. Helps you understand navigation patterns and optimize internal linking."
        },
        %{
          key: "search",
          path: "search",
          label: "Site Search",
          desc: "What visitors search for on your site using your search box. Captures query parameters (q, query, search, s, keyword) from page URLs automatically."
        },
        %{
          key: "outbound-links",
          path: "outbound-links",
          label: "Outbound Links",
          desc: "External links your visitors click. Tracked automatically — see which domains visitors leave your site for and how often."
        },
        %{
          key: "downloads",
          path: "downloads",
          label: "Downloads",
          desc: "File downloads tracked automatically (PDF, ZIP, DOC, XLS, CSV, MP3, MP4, DMG, EXE, ISO). See which files are most popular."
        },
        %{
          key: "events",
          path: "events",
          label: "Custom Events",
          desc: "Events fired via Spectabas.track() in your JavaScript. Use these for button clicks, form submissions, video plays, or any custom interaction."
        },
        %{
          key: "performance",
          path: "performance",
          label: "Performance (RUM)",
          desc: "Real User Monitoring — Core Web Vitals (LCP, CLS, FID), page load times, TTFB, DNS, and TLS timing. Broken down by page and device type."
        }
      ]
    },
    "acquisition" => %{
      title: "Acquisition",
      description: "Where your visitors come from — traffic sources, channels, and marketing campaign performance.",
      color: "emerald",
      active: "acquisition-landing",
      pages: [
        %{
          key: "acquisition",
          path: "acquisition",
          label: "Acquisition",
          desc: "Traffic channels with drill-down, referrer domains, UTM parameters, and engagement metrics — all in one view. Switch between channel overview and individual sources."
        },
        %{
          key: "campaigns",
          path: "campaigns",
          label: "Campaigns",
          desc: "UTM campaign builder and campaign performance tracking. Create tagged URLs and track how each campaign performs."
        }
      ]
    },
    "audience" => %{
      title: "Audience",
      description: "Who your visitors are — location, devices, network, behavior patterns, and individual profiles.",
      color: "amber",
      active: "audience-landing",
      pages: [
        %{
          key: "geo",
          path: "geo",
          label: "Geography",
          desc: "Visitor locations with drill-down: country, region, city. Includes full names, ISO codes, and EU flag for GDPR compliance tracking."
        },
        %{
          key: "map",
          path: "map",
          label: "Visitor Map",
          desc: "Interactive world map showing visitor density by country. Click a country to zoom into regional detail."
        },
        %{
          key: "devices",
          path: "devices",
          label: "Devices",
          desc: "Browser, operating system, device type (desktop/mobile/tablet), and screen resolution breakdowns. Helps prioritize responsive design efforts."
        },
        %{
          key: "network",
          path: "network",
          label: "Network",
          desc: "ISP/ASN data, datacenter vs residential traffic, VPN detection, and TOR usage. Useful for identifying bot networks or corporate traffic."
        },
        %{
          key: "bot-traffic",
          path: "bot-traffic",
          label: "Bot Traffic",
          desc: "Dedicated view of bot-flagged traffic. All other pages exclude bots — this page shows only bots for analysis. Includes UA detection and navigator.webdriver checks."
        },
        %{
          key: "visitor-log",
          path: "visitor-log",
          label: "Visitor Log",
          desc: "Individual visitor records with session count, pages viewed, location, device, and identified email. Click any visitor to see their full profile and event timeline."
        },
        %{
          key: "cohort",
          path: "cohort",
          label: "Cohort Retention",
          desc: "Retention heatmap showing how many visitors from each weekly cohort return in subsequent weeks. Measures stickiness of your content or product."
        },
        %{
          key: "churn-risk",
          path: "churn-risk",
          label: "Churn Risk",
          desc: "Customers with 50%+ engagement decline over 14-day windows. Flags high/medium/low risk with email links for identified users. Ecommerce customers only."
        }
      ]
    },
    "conversions" => %{
      title: "Conversions",
      description: "Revenue, goals, and purchase behavior — measure what matters for your business.",
      color: "rose",
      active: "conversions-landing",
      pages: [
        %{
          key: "goals",
          path: "goals",
          label: "Goals",
          desc: "Track specific actions: pageview goals (URL match with wildcards) and custom event goals (from Spectabas.track()). See completion count and conversion rate."
        },
        %{
          key: "funnels",
          path: "funnels",
          label: "Funnels",
          desc: "Multi-step conversion paths showing drop-off at each step. For ecommerce sites, shows revenue per step. Export drop-off visitors as CSV for remarketing."
        },
        %{
          key: "ecommerce",
          path: "ecommerce",
          label: "Ecommerce",
          desc: "Revenue and orders chart, top products with categories, recent orders. Powered by the ecommerce JavaScript API or server-side transaction endpoint."
        },
        %{
          key: "revenue-attribution",
          path: "revenue-attribution",
          label: "Revenue Attribution",
          desc: "Which traffic sources generate paying customers. Sortable table with revenue, AOV, conversion rate, and ROAS. Paid sources show colored platform pills (Google/Bing/Meta). Three attribution models: first-touch, last-touch, any-touch."
        },
        %{
          key: "revenue-cohorts",
          path: "revenue-cohorts",
          label: "Revenue Cohorts",
          desc: "Customer lifetime value by first-purchase week. Heatmap grid showing revenue per customer over time — identify when customers stop purchasing."
        },
        %{
          key: "buyer-patterns",
          path: "buyer-patterns",
          label: "Buyer Patterns",
          desc: "Side-by-side comparison of buyer vs non-buyer engagement. Page lift analysis shows which pages buyers visit more — reveals your best-converting content."
        }
      ]
    },
    "ad-effectiveness" => %{
      title: "Ad Effectiveness",
      description: "Beyond ROAS — measure the true quality and long-term value of your ad traffic.",
      color: "violet",
      active: "ad-effectiveness-landing",
      pages: [
        %{
          key: "visitor-quality",
          path: "visitor-quality",
          label: "Visitor Quality",
          desc: "Engagement score (0-100) for ad visitors by platform and campaign. Components: pages/session, duration, bounce rate, return visits, intent signals. Identifies which ad sources bring genuinely engaged visitors vs low-quality traffic."
        },
        %{
          key: "time-to-convert",
          path: "time-to-convert",
          label: "Time to Convert",
          desc: "How many days and sessions between the first ad click and purchase. Histogram distribution from same-day to 30+ days. Tells you which platforms bring ready-to-buy visitors vs those that need nurturing."
        },
        %{
          key: "ad-visitor-paths",
          path: "ad-visitor-paths",
          label: "Ad Visitor Paths",
          desc: "The most common page sequences for ad visitors, with conversion rate per path. Switch to Bounce Pages to see which landing pages lose ad visitors immediately. Optimize your ad landing experience."
        },
        %{
          key: "ad-churn",
          path: "ad-churn",
          label: "Ad-to-Churn",
          desc: "Which ad campaigns bring customers who stick vs those who churn. Compares ad traffic churn rate to organic baseline. Low churn = your ads attract the right audience."
        },
        %{
          key: "organic-lift",
          path: "organic-lift",
          label: "Organic Lift",
          desc: "Does ad spend correlate with higher organic traffic? Compares organic visitors on high-spend vs low-spend days. A positive lift suggests ads create brand awareness that drives organic discovery."
        }
      ]
    },
    "tools" => %{
      title: "Tools",
      description: "Reports, exports, and site configuration.",
      color: "gray",
      active: "tools-landing",
      pages: [
        %{
          key: "reports",
          path: "reports",
          label: "Reports",
          desc: "Generate and view analytics reports for specific date ranges. Snapshot your data for stakeholder presentations or periodic reviews."
        },
        %{
          key: "email-reports",
          path: "email-reports",
          label: "Email Reports",
          desc: "Automated email digests — daily, weekly, or monthly. HTML emails with period comparison, top pages, sources, and countries. One-click unsubscribe."
        },
        %{
          key: "exports",
          path: "exports",
          label: "Exports",
          desc: "Download your analytics data as CSV for external analysis. Export visitors, pageviews, sources, or any other dimension."
        },
        %{
          key: "settings",
          path: "settings",
          label: "Settings",
          desc: "Site configuration: domain, timezone, GDPR mode, ecommerce toggle, tracking snippet, DNS verification, and ad platform integrations (Google Ads, Bing, Meta)."
        }
      ]
    }
  }

  @impl true
  def mount(%{"site_id" => site_id, "category" => category}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      cat = @categories[category]

      if cat do
        {:ok,
         socket
         |> assign(:page_title, cat.title)
         |> assign(:site, site)
         |> assign(:category, cat)
         |> assign(:category_slug, category)}
      else
        {:ok, socket |> redirect(to: ~p"/dashboard/sites/#{site_id}")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title={@category.title}
      page_description={@category.description}
      active={@category.active}
      live_visitors={0}
    >
      <div class="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-gray-900">{@category.title}</h1>
          <p class="text-sm text-gray-500 mt-1 max-w-2xl">{@category.description}</p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <.link
            :for={page <- @category.pages}
            navigate={page_path(@site.id, page.path)}
            class="bg-white rounded-lg shadow-sm border border-gray-200 p-5 hover:border-indigo-300 hover:shadow transition-all group"
          >
            <div class="flex items-start justify-between">
              <h3 class={"text-base font-semibold text-gray-900 group-hover:text-#{@category.color}-600"}>
                {page.label}
              </h3>
              <span class="text-gray-300 group-hover:text-indigo-400 text-sm shrink-0 ml-2">&rarr;</span>
            </div>
            <p class="text-sm text-gray-500 mt-2 leading-relaxed">
              {page.desc}
            </p>
          </.link>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp page_path(site_id, ""), do: ~p"/dashboard/sites/#{site_id}"
  defp page_path(site_id, path), do: "/dashboard/sites/#{site_id}/#{path}"
end
