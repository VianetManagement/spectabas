defmodule SpectabasWeb.Dashboard.VisitorLive do
  use SpectabasWeb, :live_view

  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  alias Spectabas.{Accounts, Sites, Visitors, Analytics}
  alias Spectabas.Webhooks.ScraperWebhook

  @impl true
  def mount(%{"site_id" => site_id, "visitor_id" => visitor_id} = params, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      visitor = Visitors.get_visitor!(visitor_id)

      # Fast: single ClickHouse aggregation
      profile =
        case Analytics.visitor_profile(site, visitor_id) do
          {:ok, p} when is_map(p) -> p
          _ -> %{}
        end

      last_ip =
        params["ip"] ||
          visitor.last_ip ||
          get_in(List.first([]) || %{}, ["ip_address"])

      socket =
        socket
        |> assign(:page_title, "Visitor - #{site.name}")
        |> assign(:site, site)
        |> assign(:visitor, visitor)
        |> assign(:visitor_id, visitor_id)
        |> assign(:profile, profile)
        |> assign(:last_ip, last_ip)
        |> assign(:show_ip_panel, false)
        # Deferred assigns — nil means "loading"
        |> assign(:timeline, nil)
        |> assign(:sessions, nil)
        |> assign(:ip_info, nil)
        |> assign(:ip_visitors, nil)
        |> assign(:fp_visitors, nil)
        |> assign(:visitor_ips, nil)
        |> assign(:orders, nil)
        |> assign(:ltv, nil)
        |> assign(:scraper, nil)
        |> assign(:webhook_deliveries, nil)
        |> assign(:vpn_provider, nil)
        |> assign(:deferred_loaded, false)

      if connected?(socket), do: send(self(), :load_deferred)

      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_deferred, socket) do
    site = socket.assigns.site
    visitor_id = socket.assigns.visitor_id
    last_ip = socket.assigns.last_ip
    profile = socket.assigns.profile
    lv_pid = self()

    # Spawn each deferred query as an independent task
    # Timeline + scraper score (timeline needed for score computation)
    Task.start(fn ->
      timeline =
        case Analytics.visitor_timeline(site, visitor_id) do
          {:ok, events} -> events
          _ -> []
        end

      sessions =
        timeline
        |> Enum.group_by(& &1["session_id"])
        |> Enum.map(fn {sid, events} ->
          events = Enum.sort_by(events, & &1["timestamp"])
          pageviews = Enum.filter(events, &(&1["event_type"] == "pageview"))

          %{
            session_id: sid,
            started: List.first(events)["timestamp"],
            pages: length(pageviews),
            entry: List.first(pageviews)["url_path"],
            exit: List.last(pageviews)["url_path"],
            referrer: List.first(events)["referrer_domain"],
            duration: events |> Enum.map(&to_num(&1["duration_s"])) |> Enum.max(fn -> 0 end)
          }
        end)
        |> Enum.sort_by(& &1.started, :desc)

      # Use dedicated ClickHouse aggregation for scraper score — matches the
      # Scrapers page exactly. The timeline-based computation was limited to
      # ~1000 events and undercounted unique pages for heavy scrapers.
      scraper =
        case Analytics.scraper_score_for_visitor(site, visitor_id) do
          {:ok, result} -> result
          _ -> %{score: 0, signals: [], verdict: :normal, unique_pages: 0, ip_count: 0}
        end

      send(lv_pid, {:deferred_result, :timeline, timeline})
      send(lv_pid, {:deferred_result, :sessions, sessions})
      send(lv_pid, {:deferred_result, :scraper, scraper})
    end)

    # IP details + other visitors from same IP
    Task.start(fn ->
      {ip_info, ip_visitors} =
        if last_ip && last_ip != "" do
          info =
            case Analytics.ip_details(site, last_ip) do
              {:ok, i} -> i
              _ -> nil
            end

          visitors =
            case Analytics.visitors_by_ip(site, last_ip) do
              {:ok, rows} -> Enum.reject(rows, &(&1["visitor_id"] == visitor_id))
              _ -> []
            end

          {info, visitors}
        else
          {nil, []}
        end

      send(lv_pid, {:deferred_result, :ip_info, ip_info})
      send(lv_pid, {:deferred_result, :ip_visitors, ip_visitors})
    end)

    # Fingerprint matches
    Task.start(fn ->
      fingerprint = profile["browser_fingerprint"]

      fp_visitors =
        if fingerprint && fingerprint != "" do
          case Analytics.visitors_by_fingerprint(site, fingerprint) do
            {:ok, rows} -> Enum.reject(rows, &(&1["visitor_id"] == visitor_id))
            _ -> []
          end
        else
          []
        end

      send(lv_pid, {:deferred_result, :fp_visitors, fp_visitors})
    end)

    # IP address history
    Task.start(fn ->
      ips =
        case Analytics.visitor_ips(site, visitor_id) do
          {:ok, rows} -> rows
          _ -> []
        end

      send(lv_pid, {:deferred_result, :visitor_ips, ips})
    end)

    # Real-time VPN/privacy relay lookup (checks live Geolix databases, not stored ClickHouse data)
    Task.start(fn ->
      vpn = Spectabas.IPEnricher.vpn_provider_for_ip(last_ip || "")
      send(lv_pid, {:deferred_result, :vpn_provider, vpn})
    end)

    # Ecommerce data
    Task.start(fn ->
      {orders, ltv} =
        if site.ecommerce_enabled do
          ord =
            case Analytics.visitor_orders(site, visitor_id) do
              {:ok, rows} -> rows
              _ -> []
            end

          l =
            case Analytics.visitor_ltv(site, visitor_id) do
              {:ok, [row | _]} -> row
              _ -> nil
            end

          {ord, l}
        else
          {[], nil}
        end

      send(lv_pid, {:deferred_result, :orders, orders})
      send(lv_pid, {:deferred_result, :ltv, ltv})
    end)

    # Webhook deliveries (Postgres, fast)
    Task.start(fn ->
      deliveries = ScraperWebhook.list_visitor_deliveries(visitor_id)
      send(lv_pid, {:deferred_result, :webhook_deliveries, deliveries})
    end)

    {:noreply, socket}
  end

  def handle_info({:deferred_result, key, value}, socket) do
    {:noreply, assign(socket, key, value)}
  end

  @impl true
  def handle_event("toggle_ip_panel", _params, socket) do
    {:noreply, assign(socket, :show_ip_panel, !socket.assigns.show_ip_panel)}
  end

  def handle_event("unflag_scraper", _params, socket) do
    site = socket.assigns.site
    visitor = socket.assigns.visitor

    result =
      if site.scraper_webhook_enabled && site.scraper_webhook_url do
        Spectabas.Webhooks.ScraperWebhook.send_deactivate(site, visitor)
      else
        {:ok, %{status: "no webhook configured"}}
      end

    case result do
      {:ok, _} ->
        visitor
        |> Spectabas.Visitors.Visitor.changeset(%{
          scraper_webhook_sent_at: nil,
          scraper_webhook_score: nil
        })
        |> Spectabas.Repo.update()

        {:noreply,
         socket
         |> assign(:visitor, Spectabas.Repo.get!(Spectabas.Visitors.Visitor, visitor.id))
         |> assign(:status, :deactivated)
         |> put_flash(:info, "Visitor unflagged — deactivation webhook sent.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to send deactivation webhook.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout flash={@flash} site={@site} active="visitor-log" live_visitors={0}>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <div class="mb-6">
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/visitor-log"}
            class="text-sm text-indigo-600 hover:text-indigo-800"
          >
            &larr; Visitor Log
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Visitor Profile</h1>
        </div>

        <%!-- Webhook Status Banner --%>
        <.webhook_status_banner
          visitor={@visitor}
          webhook_deliveries={@webhook_deliveries}
          site={@site}
        />

        <%!-- Top stats row --%>
        <div class={"grid grid-cols-2 gap-4 mb-6 " <> if(@ltv, do: "md:grid-cols-6", else: "md:grid-cols-5")}>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Pageviews</dt>
            <dd class="mt-1 text-2xl font-bold text-gray-900">{@profile["total_pageviews"] || 0}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Sessions</dt>
            <dd class="mt-1 text-2xl font-bold text-gray-900">{@profile["total_sessions"] || 0}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">First Seen</dt>
            <dd class="mt-1 text-sm font-bold text-gray-900">{@profile["first_seen"] || "-"}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Last Seen</dt>
            <dd class="mt-1 text-sm font-bold text-gray-900">{@profile["last_seen"] || "-"}</dd>
          </div>
          <div class="bg-white rounded-lg shadow p-4">
            <dt class="text-xs font-medium text-gray-500">Duration</dt>
            <dd class="mt-1 text-2xl font-bold text-gray-900">
              {format_duration(to_num(@profile["total_duration"]))}
            </dd>
          </div>
          <%= if @ltv do %>
            <div class="bg-white rounded-lg shadow p-4 border-l-4 border-green-400">
              <dt class="text-xs font-medium text-gray-500">Lifetime Value</dt>
              <dd class="mt-1 text-2xl font-bold text-green-700">
                {Spectabas.Currency.format(to_float(@ltv["net_revenue"]), @site.currency)}
              </dd>
              <dd class="text-xs text-gray-500 mt-0.5">
                {to_num(@ltv["total_orders"])} orders
                <%= if to_float(@ltv["total_refunds"]) > 0 do %>
                  &middot; {Spectabas.Currency.format(to_float(@ltv["total_refunds"]), @site.currency)} refunded
                <% end %>
              </dd>
            </div>
          <% end %>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-6">
          <%!-- Identity & Device --%>
          <div class="bg-white rounded-lg shadow p-5">
            <h3 class="text-sm font-semibold text-gray-700 mb-3 uppercase">Identity & Device</h3>
            <dl class="space-y-2 text-sm">
              <.field
                label="Visitor ID"
                value={String.slice(to_string(@visitor.id), 0, 12) <> "..."}
                mono={true}
              />
              <.field :if={@visitor.email} label="Email" value={@visitor.email} />
              <.field :if={@visitor.user_id} label="User ID" value={@visitor.user_id} mono={true} />
              <.field
                :if={@visitor.external_id}
                label="External ID"
                value={@visitor.external_id}
                mono={true}
              />
              <.field
                label="Browser"
                value={"#{@profile["browser"] || "?"} #{@profile["browser_version"] || ""}"}
              />
              <.field label="OS" value={"#{@profile["os"] || "?"} #{@profile["os_version"] || ""}"} />
              <.field label="Device" value={@profile["device_type"] || "Unknown"} />
              <.field
                label="Screen"
                value={"#{@profile["screen_width"] || "?"}x#{@profile["screen_height"] || "?"}"}
              />
              <.field
                label="ID Type"
                value={if @visitor.cookie_id, do: "Cookie", else: "Fingerprint"}
              />
              <.field label="GDPR Mode" value={@site.gdpr_mode || "on"} />
              <%!-- Scraper score (deferred) --%>
              <%= if @scraper == nil do %>
                <div>
                  <dt class="text-xs font-medium text-gray-500">Scraper Score</dt>
                  <dd class="mt-0.5">
                    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs text-gray-400">
                      Loading...
                    </span>
                  </dd>
                </div>
              <% else %>
                <div :if={@scraper.score > 0}>
                  <dt class="text-xs font-medium text-gray-500">Scraper Score</dt>
                  <dd class="mt-0.5 flex items-center gap-2">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-bold",
                      cond do
                        @scraper.score >= 85 -> "bg-red-100 text-red-800"
                        @scraper.score >= 60 -> "bg-amber-100 text-amber-800"
                        true -> "bg-gray-100 text-gray-700"
                      end
                    ]}>
                      {@scraper.score}
                    </span>
                    <span class="text-xs text-gray-500">
                      {cond do
                        @scraper.score >= 85 -> "certain"
                        @scraper.score >= 60 -> "suspicious"
                        true -> "low"
                      end}
                    </span>
                  </dd>
                  <dd :if={@scraper.signals != []} class="mt-1 flex flex-wrap gap-1">
                    <span
                      :for={sig <- @scraper.signals}
                      class="inline-flex items-center px-1.5 py-0 rounded text-[10px] font-medium bg-gray-100 text-gray-600"
                    >
                      {sig}
                    </span>
                  </dd>
                </div>
              <% end %>
              <div :if={@profile["browser_fingerprint"] && @profile["browser_fingerprint"] != ""}>
                <dt class="text-xs font-medium text-gray-500">Browser Fingerprint</dt>
                <dd class="mt-0.5 text-xs text-indigo-600 font-mono">
                  {@profile["browser_fingerprint"]}
                  <%= if @fp_visitors != nil do %>
                    <span
                      :if={@fp_visitors != [] && length(@fp_visitors) <= 10}
                      class="text-amber-600 ml-1"
                    >
                      ({length(@fp_visitors)} other visitors share this fingerprint)
                    </span>
                    <span
                      :if={@fp_visitors != nil && length(@fp_visitors) > 10}
                      class="text-gray-400 ml-1"
                    >
                      (common device — {length(@fp_visitors)} matches)
                    </span>
                  <% end %>
                </dd>
              </div>
              <div :if={@profile["user_agent"] && @profile["user_agent"] != ""}>
                <dt class="text-xs font-medium text-gray-500">User Agent</dt>
                <dd class="mt-0.5 text-xs text-gray-600 font-mono break-all leading-relaxed">
                  {@profile["user_agent"]}
                </dd>
              </div>
            </dl>
          </div>

          <%!-- Location & Network --%>
          <div class="bg-white rounded-lg shadow p-5">
            <h3 class="text-sm font-semibold text-gray-700 mb-3 uppercase">Location & Network</h3>
            <dl class="space-y-2 text-sm">
              <.field
                label="Country"
                value={"#{@profile["country_name"] || ""} (#{@profile["country"] || "?"})"}
              />
              <.field label="Region" value={@profile["region"] || "-"} />
              <.field label="City" value={@profile["city"] || "-"} />
              <.field label="Timezone" value={@profile["timezone"] || "-"} />
              <.field label="ISP / Org" value={@profile["org"] || "-"} />
              <div class="flex gap-2 pt-1">
                <span
                  :if={@profile["is_datacenter"] == "1" || @profile["is_datacenter"] == 1}
                  class="px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"
                >
                  Datacenter
                </span>
                <span
                  :if={
                    @profile["is_vpn"] == "1" || @profile["is_vpn"] == 1 ||
                      (@vpn_provider && @vpn_provider != "")
                  }
                  class="px-2 py-0.5 rounded text-xs font-medium bg-purple-100 text-purple-800"
                >
                  VPN{cond do
                    @vpn_provider && @vpn_provider != "" ->
                      " (#{@vpn_provider})"

                    @profile["vpn_provider"] && @profile["vpn_provider"] != "" ->
                      " (#{@profile["vpn_provider"]})"

                    true ->
                      ""
                  end}
                </span>
                <span
                  :if={@profile["is_bot"] == "1" || @profile["is_bot"] == 1}
                  class="px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800"
                >
                  Bot
                </span>
              </div>
            </dl>
          </div>

          <%!-- Acquisition & Behavior --%>
          <div class="bg-white rounded-lg shadow p-5">
            <h3 class="text-sm font-semibold text-gray-700 mb-3 uppercase">Acquisition & Behavior</h3>
            <dl class="space-y-2 text-sm">
              <.field label="Original Referrer" value={@profile["original_referrer"] || "Direct"} />
              <.field label="First Page" value={@profile["first_page"] || "-"} mono={true} />
              <.field label="Last Page" value={@profile["last_page"] || "-"} mono={true} />
              <%!-- Ad Click ID Attribution --%>
              <div :if={@profile["first_click_id"] && @profile["first_click_id"] != ""}>
                <dt class="text-xs font-medium text-gray-500">Ad Click ID</dt>
                <dd class="mt-0.5 flex items-center gap-2">
                  <span class={[
                    "px-2 py-0.5 rounded text-xs font-medium",
                    click_platform_class(@profile["first_click_id_type"])
                  ]}>
                    {click_platform_label(@profile["first_click_id_type"])}
                  </span>
                  <span class="text-xs font-mono text-gray-500 truncate max-w-[200px]">
                    {@profile["first_click_id"]}
                  </span>
                </dd>
              </div>
              <div :if={
                (@profile["click_id_platforms"] || []) != [] &&
                  length(@profile["click_id_platforms"] || []) > 1
              }>
                <dt class="text-xs font-medium text-gray-500">All Ad Platforms</dt>
                <dd class="mt-0.5 flex flex-wrap gap-1">
                  <span
                    :for={p <- @profile["click_id_platforms"]}
                    class={["px-2 py-0.5 rounded text-xs font-medium", click_platform_class(p)]}
                  >
                    {click_platform_label(p)}
                  </span>
                </dd>
              </div>
              <%!-- UTM Parameters --%>
              <.utm_tags label="UTM Source" values={@profile["utm_sources"]} />
              <.utm_tags label="UTM Medium" values={@profile["utm_mediums"]} />
              <.utm_tags label="UTM Campaign" values={@profile["utm_campaigns"]} />
              <.utm_tags label="UTM Term" values={@profile["utm_terms"]} />
              <.utm_tags label="UTM Content" values={@profile["utm_contents"]} />
              <div :if={@profile["top_pages"] && @profile["top_pages"] != []}>
                <dt class="text-xs font-medium text-gray-500">Top Pages</dt>
                <dd class="mt-0.5 space-y-0.5">
                  <div
                    :for={page <- List.wrap(@profile["top_pages"])}
                    class="text-xs font-mono text-gray-600 truncate"
                  >
                    {page}
                  </div>
                </dd>
              </div>
            </dl>
          </div>
        </div>

        <%!-- Webhook Delivery History --%>
        <.webhook_history deliveries={@webhook_deliveries} site={@site} />

        <%!-- IP Details Panel --%>
        <div :if={@last_ip} class="bg-white rounded-lg shadow mb-6">
          <button
            phx-click="toggle_ip_panel"
            class="w-full px-5 py-4 flex items-center justify-between text-left"
          >
            <div>
              <h3 class="text-sm font-semibold text-gray-700">
                IP Address: <span class="font-mono text-indigo-600">{@last_ip}</span>
              </h3>
              <p class="text-xs text-gray-500 mt-0.5">
                <%= if @ip_visitors != nil do %>
                  {length(@ip_visitors)} other visitor(s) from this IP
                <% else %>
                  Loading...
                <% end %>
                {if @ip_info,
                  do:
                    " · #{@ip_info["ip_city"]}, #{@ip_info["ip_region_name"]}, #{@ip_info["ip_country"]}",
                  else: ""}
              </p>
            </div>
            <span class="text-gray-500 text-sm">
              {if @show_ip_panel, do: "Hide", else: "Show details"}
            </span>
          </button>

          <div :if={@show_ip_panel} class="border-t border-gray-100 px-5 py-4">
            <%!-- IP enrichment details --%>
            <div :if={@ip_info} class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
              <.field
                label="Country"
                value={"#{@ip_info["ip_country_name"]} (#{@ip_info["ip_country"]})"}
              />
              <.field label="Region" value={@ip_info["ip_region_name"] || "-"} />
              <.field label="City" value={@ip_info["ip_city"] || "-"} />
              <.field label="Postal Code" value={@ip_info["ip_postal_code"] || "-"} />
              <.field label="Continent" value={@ip_info["ip_continent_name"] || "-"} />
              <.field label="Timezone" value={@ip_info["ip_timezone"] || "-"} />
              <.field label="Lat / Lon" value={"#{@ip_info["ip_lat"]}, #{@ip_info["ip_lon"]}"} />
              <.field label="ASN" value={"AS#{@ip_info["ip_asn"]} #{@ip_info["ip_asn_org"]}"} />
            </div>

            <%!-- Other visitors from same IP --%>
            <div :if={@ip_visitors != nil && @ip_visitors != []}>
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">
                Other visitors from this IP
              </h4>
              <table class="min-w-full divide-y divide-gray-200 text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-3 py-2 text-left text-xs text-gray-500">Visitor</th>
                    <th class="px-3 py-2 text-left text-xs text-gray-500">Last Seen</th>
                    <th class="px-3 py-2 text-right text-xs text-gray-500">Pages</th>
                    <th class="px-3 py-2 text-left text-xs text-gray-500">Device</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <tr :for={v <- @ip_visitors} class="hover:bg-gray-50">
                    <td class="px-3 py-2">
                      <.link
                        navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                        class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                      >
                        {String.slice(v["visitor_id"] || "", 0, 10)}...
                      </.link>
                    </td>
                    <td class="px-3 py-2 text-gray-500 text-xs">{v["last_seen"]}</td>
                    <td class="px-3 py-2 text-gray-900 text-right tabular-nums">
                      {format_number(to_num(v["pageviews"]))}
                    </td>
                    <td class="px-3 py-2 text-gray-500 text-xs">
                      {[v["browser"], v["os"]]
                      |> Enum.reject(&(&1 == "" || is_nil(&1)))
                      |> Enum.join(" / ")}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Known IPs --%>
            <div :if={@visitor.known_ips != [] && length(@visitor.known_ips) > 1} class="mt-4">
              <h4 class="text-xs font-semibold text-gray-500 uppercase mb-2">All known IPs</h4>
              <div class="flex flex-wrap gap-2">
                <span
                  :for={ip <- @visitor.known_ips}
                  class="px-2 py-1 rounded text-xs font-mono bg-gray-100 text-gray-700"
                >
                  {ip}
                </span>
              </div>
            </div>
          </div>
        </div>

        <%!-- IP Address History --%>
        <.loading_section loaded={@visitor_ips != nil}>
          <div :if={@visitor_ips != nil && @visitor_ips != []} class="bg-white rounded-lg shadow mb-6">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="text-sm font-semibold text-gray-700">
                IP Addresses Used ({length(@visitor_ips)})
              </h3>
            </div>
            <table class="min-w-full divide-y divide-gray-200 text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">IP Address</th>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">Location</th>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">Organization</th>
                  <th class="px-4 py-2 text-right text-xs text-gray-500">Events</th>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">Last Seen</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={ip <- @visitor_ips} class="hover:bg-gray-50">
                  <td class="px-4 py-2">
                    <.link
                      navigate={~p"/dashboard/sites/#{@site.id}/ip/#{ip["ip_address"]}"}
                      class="font-mono text-xs text-indigo-600 hover:text-indigo-800"
                    >
                      {ip["ip_address"]}
                    </.link>
                    <span
                      :if={ip["is_datacenter"] == "1" || ip["is_datacenter"] == 1}
                      class="ml-1 text-[10px] bg-orange-100 text-orange-700 px-1 rounded"
                    >
                      DC
                    </span>
                    <span
                      :if={ip["is_vpn"] == "1" || ip["is_vpn"] == 1}
                      class="ml-1 text-[10px] bg-yellow-100 text-yellow-700 px-1 rounded"
                    >
                      VPN
                    </span>
                  </td>
                  <td class="px-4 py-2 text-gray-600">
                    {[ip["city"], ip["country"]]
                    |> Enum.reject(&(&1 == "" || is_nil(&1)))
                    |> Enum.join(", ")}
                  </td>
                  <td class="px-4 py-2 text-gray-500 text-xs">{ip["org"]}</td>
                  <td class="px-4 py-2 text-gray-900 text-right tabular-nums">{ip["events"]}</td>
                  <td class="px-4 py-2 text-gray-500 text-xs">{ip["last_seen"]}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </.loading_section>

        <%!-- Session History --%>
        <.loading_section loaded={@sessions != nil}>
          <div :if={@sessions != nil} class="bg-white rounded-lg shadow mb-6">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="text-sm font-semibold text-gray-700">Sessions ({length(@sessions)})</h3>
            </div>
            <table class="min-w-full divide-y divide-gray-200 text-sm">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">Started</th>
                  <th class="px-4 py-2 text-right text-xs text-gray-500">Pages</th>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">Entry</th>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">Exit</th>
                  <th class="px-4 py-2 text-left text-xs text-gray-500">Referrer</th>
                  <th class="px-4 py-2 text-right text-xs text-gray-500">Duration</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <tr :for={s <- @sessions} class="hover:bg-gray-50">
                  <td class="px-4 py-2 text-gray-500 text-xs">{s.started}</td>
                  <td class="px-4 py-2 text-gray-900 text-right tabular-nums">{s.pages}</td>
                  <td class="px-4 py-2 text-gray-700 font-mono text-xs truncate max-w-[150px]">
                    {s.entry}
                  </td>
                  <td class="px-4 py-2 text-gray-700 font-mono text-xs truncate max-w-[150px]">
                    {s.exit}
                  </td>
                  <td class="px-4 py-2 text-gray-500 text-xs truncate max-w-[120px]">
                    {s.referrer || "Direct"}
                  </td>
                  <td class="px-4 py-2 text-gray-900 text-right tabular-nums">
                    {format_duration(s.duration)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.loading_section>

        <%!-- Ecommerce Orders --%>
        <div :if={@orders != nil && @orders != []} class="bg-white rounded-lg shadow mb-6">
          <div class="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
            <h3 class="text-sm font-semibold text-gray-700">
              Orders ({length(@orders)})
            </h3>
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/ecommerce"}
              class="text-xs text-indigo-600 hover:text-indigo-800"
            >
              View all ecommerce &rarr;
            </.link>
          </div>
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Order ID</th>
                <th class="px-4 py-2 text-right text-xs text-gray-500">Revenue</th>
                <th class="px-4 py-2 text-right text-xs text-gray-500">Tax</th>
                <th class="px-4 py-2 text-right text-xs text-gray-500">Shipping</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Items</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Time</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={order <- @orders} class="hover:bg-gray-50">
                <td class="px-4 py-2 font-mono text-xs text-gray-900">{order["order_id"]}</td>
                <td class="px-4 py-2 text-right tabular-nums font-medium text-green-600">
                  {Spectabas.Currency.format(format_order_amount(order["revenue"]), @site.currency)}
                </td>
                <td class="px-4 py-2 text-right tabular-nums text-gray-500">
                  {format_order_amount(order["tax"])}
                </td>
                <td class="px-4 py-2 text-right tabular-nums text-gray-500">
                  {format_order_amount(order["shipping"])}
                </td>
                <td class="px-4 py-2 text-gray-500 text-xs">
                  {parse_items(order["items"])}
                </td>
                <td class="px-4 py-2 text-gray-500 text-xs">{order["timestamp"]}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Browser Fingerprint Cross-Reference (only useful when < 10 matches) --%>
        <div
          :if={@fp_visitors != nil && @fp_visitors != [] && length(@fp_visitors) <= 10}
          class="bg-white rounded-lg shadow mb-6"
        >
          <div class="px-5 py-4 border-b border-gray-100">
            <h3 class="text-sm font-semibold text-gray-700">
              Same Browser Fingerprint ({length(@fp_visitors)} other visitors)
            </h3>
            <p class="text-xs text-gray-500 mt-0.5">
              These visitors share the same browser fingerprint — possible alt accounts or shared device.
            </p>
          </div>
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-3 py-2 text-left text-xs text-gray-500">Visitor</th>
                <th class="px-3 py-2 text-left text-xs text-gray-500">Last Seen</th>
                <th class="px-3 py-2 text-right text-xs text-gray-500">Pages</th>
                <th class="px-3 py-2 text-left text-xs text-gray-500">IP</th>
                <th class="px-3 py-2 text-left text-xs text-gray-500">Location</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={v <- @fp_visitors} class="hover:bg-gray-50">
                <td class="px-3 py-2">
                  <.link
                    navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v["visitor_id"]}"}
                    class="text-indigo-600 hover:text-indigo-800 font-mono text-xs"
                  >
                    {String.slice(v["visitor_id"] || "", 0, 10)}...
                  </.link>
                </td>
                <td class="px-3 py-2 text-gray-500 text-xs">{v["last_seen"]}</td>
                <td class="px-3 py-2 text-gray-900 text-right tabular-nums">
                  {format_number(to_num(v["pageviews"]))}
                </td>
                <td class="px-3 py-2 text-gray-500 font-mono text-xs">{v["ip_address"]}</td>
                <td class="px-3 py-2 text-gray-500 text-xs">
                  {[v["city"], v["country"]]
                  |> Enum.reject(&(&1 == "" || is_nil(&1)))
                  |> Enum.join(", ")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- High collision fingerprint notice --%>
        <div
          :if={@fp_visitors != nil && @fp_visitors != [] && length(@fp_visitors) > 10}
          class="bg-white rounded-lg shadow mb-6 px-5 py-4"
        >
          <p class="text-sm text-gray-500">
            <span class="font-medium text-gray-700">Browser Fingerprint:</span>
            {length(@fp_visitors)} other visitors share this fingerprint.
            This is a common device/browser combination — not useful for identifying alt accounts.
          </p>
        </div>

        <%!-- Event Timeline --%>
        <.loading_section loaded={@timeline != nil}>
          <div :if={@timeline != nil} class="bg-white rounded-lg shadow">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="text-sm font-semibold text-gray-700">
                Event Timeline ({length(@timeline)} events)
              </h3>
            </div>
            <div :if={@timeline == []} class="px-5 py-8 text-center text-gray-500">
              No events recorded.
            </div>
            <ul class="divide-y divide-gray-50">
              <li
                :for={event <- @timeline}
                class="px-5 py-2.5 flex items-center justify-between text-sm"
              >
                <div class="flex items-center gap-3 min-w-0">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium shrink-0",
                    event_type_class(event["event_type"])
                  ]}>
                    {event["event_type"]}
                  </span>
                  <span class="text-gray-900 truncate font-mono text-xs">{event["url_path"]}</span>
                  <span
                    :if={event["event_name"] && event["event_name"] != ""}
                    class="text-gray-500 text-xs"
                  >
                    ({event["event_name"]})
                  </span>
                  <span
                    :if={to_num(event["duration_s"]) > 0}
                    class="text-gray-500 text-xs"
                  >
                    {format_duration(to_num(event["duration_s"]))}
                  </span>
                </div>
                <span class="text-xs text-gray-500 shrink-0 ml-4">{event["timestamp"]}</span>
              </li>
            </ul>
          </div>
        </.loading_section>
      </div>
    </.dashboard_layout>
    """
  end

  # --- Component functions ---

  defp webhook_status_banner(assigns) do
    # Determine current webhook state from visitor record + deliveries
    status = webhook_status(assigns.visitor, assigns.webhook_deliveries)
    assigns = assign(assigns, :status, status)

    ~H"""
    <%= case @status do %>
      <% :flagged -> %>
        <div class="mb-6 rounded-lg border border-red-200 bg-red-50 p-4 flex items-center gap-3">
          <div class="flex-shrink-0">
            <.icon name="hero-shield-exclamation" class="w-6 h-6 text-red-600" />
          </div>
          <div class="flex-1">
            <h3 class="text-sm font-semibold text-red-800">Scraper Webhook Triggered</h3>
            <p class="text-xs text-red-700 mt-0.5">
              This visitor was flagged as a scraper via webhook {if @visitor.scraper_webhook_sent_at,
                do:
                  "on #{Calendar.strftime(@visitor.scraper_webhook_sent_at, "%b %d, %Y at %H:%M UTC")}",
                else: ""} with score {@visitor.scraper_webhook_score || "?"}.
            </p>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <button
              phx-click="unflag_scraper"
              data-confirm="This will send a deactivation webhook and clear the scraper flag. Continue?"
              class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-white bg-green-600 hover:bg-green-700 shadow-sm"
            >
              Unflag
            </button>
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/scrapers"}
              class="text-xs text-red-700 hover:text-red-900 font-medium"
            >
              View Scrapers &rarr;
            </.link>
          </div>
        </div>
      <% :deactivated -> %>
        <div class="mb-6 rounded-lg border border-green-200 bg-green-50 p-4 flex items-center gap-3">
          <div class="flex-shrink-0">
            <.icon name="hero-shield-check" class="w-6 h-6 text-green-600" />
          </div>
          <div class="flex-1">
            <h3 class="text-sm font-semibold text-green-800">Scraper Webhook Deactivated</h3>
            <p class="text-xs text-green-700 mt-0.5">
              This visitor was previously flagged but has been deactivated (marked as not a scraper).
            </p>
          </div>
        </div>
      <% :loading -> %>
        <div class="mb-6 rounded-lg border border-gray-200 bg-gray-50 p-3 flex items-center gap-2">
          <div class="animate-spin h-4 w-4 border-2 border-gray-300 border-t-gray-600 rounded-full">
          </div>
          <span class="text-xs text-gray-500">Loading webhook status...</span>
        </div>
      <% _ -> %>
    <% end %>
    """
  end

  defp webhook_history(assigns) do
    ~H"""
    <%= cond do %>
      <% @deliveries == nil -> %>
        <%!-- Still loading --%>
      <% @deliveries != [] -> %>
        <div class="bg-white rounded-lg shadow mb-6">
          <div class="px-5 py-4 border-b border-gray-100 flex items-center justify-between">
            <h3 class="text-sm font-semibold text-gray-700">
              Webhook Activity ({length(@deliveries)})
            </h3>
            <.link
              navigate={~p"/dashboard/sites/#{@site.id}/scrapers"}
              class="text-xs text-indigo-600 hover:text-indigo-800"
            >
              View all webhooks &rarr;
            </.link>
          </div>
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Time</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Event</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Score</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Signals</th>
                <th class="px-4 py-2 text-left text-xs text-gray-500">Status</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={d <- @deliveries} class="hover:bg-gray-50">
                <td class="px-4 py-2 text-gray-500 text-xs">
                  {Calendar.strftime(d.inserted_at, "%b %d, %Y %H:%M")}
                </td>
                <td class="px-4 py-2">
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    if(d.event_type == "flag",
                      do: "bg-red-100 text-red-800",
                      else: "bg-green-100 text-green-800"
                    )
                  ]}>
                    {if d.event_type == "flag", do: "Flagged", else: "Deactivated"}
                  </span>
                </td>
                <td class="px-4 py-2 text-gray-900 tabular-nums">
                  {d.score || "-"}
                </td>
                <td class="px-4 py-2">
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={sig <- d.signals || []}
                      class="inline-flex items-center px-1.5 py-0 rounded text-[10px] font-medium bg-gray-100 text-gray-600"
                    >
                      {sig}
                    </span>
                  </div>
                </td>
                <td class="px-4 py-2">
                  <%= if d.success do %>
                    <span class="inline-flex items-center gap-1 text-xs text-green-700">
                      <.icon name="hero-check-circle-mini" class="w-3.5 h-3.5" /> {d.http_status}
                    </span>
                  <% else %>
                    <span class="inline-flex items-center gap-1 text-xs text-red-700">
                      <.icon name="hero-x-circle-mini" class="w-3.5 h-3.5" />
                      {d.error_message || "HTTP #{d.http_status}"}
                    </span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% true -> %>
        <%!-- No deliveries, show nothing --%>
    <% end %>
    """
  end

  defp loading_section(assigns) do
    ~H"""
    <%= if @loaded do %>
      {render_slot(@inner_block)}
    <% else %>
      <div class="bg-white rounded-lg shadow mb-6 px-5 py-6 flex items-center justify-center">
        <div class="animate-spin h-5 w-5 border-2 border-gray-300 border-t-indigo-600 rounded-full mr-3">
        </div>
        <span class="text-sm text-gray-400">Loading...</span>
      </div>
    <% end %>
    """
  end

  defp webhook_status(visitor, deliveries) do
    cond do
      deliveries == nil ->
        :loading

      visitor.scraper_webhook_sent_at != nil ->
        # Check if most recent delivery is a deactivate
        latest = List.first(deliveries)

        if latest && latest.event_type == "deactivate" do
          :deactivated
        else
          :flagged
        end

      true ->
        :none
    end
  end

  defp field(assigns) do
    assigns = assigns |> Map.put_new(:mono, false)

    ~H"""
    <div>
      <dt class="text-xs font-medium text-gray-500">{@label}</dt>
      <dd class={["mt-0.5 text-gray-900", if(@mono, do: "font-mono text-xs", else: "")]}>
        {@value}
      </dd>
    </div>
    """
  end

  defp event_type_class("pageview"), do: "bg-blue-100 text-blue-800"
  defp event_type_class("duration"), do: "bg-gray-100 text-gray-600"
  defp event_type_class("custom"), do: "bg-purple-100 text-purple-800"
  defp event_type_class("ecommerce_order"), do: "bg-green-100 text-green-800"
  defp event_type_class(_), do: "bg-gray-100 text-gray-800"

  defp format_order_amount(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 2)
      :error -> "0.00"
    end
  end

  defp format_order_amount(n) when is_number(n),
    do: :erlang.float_to_binary(n / 1, decimals: 2)

  defp format_order_amount(_), do: "0.00"

  defp parse_items(nil), do: "-"
  defp parse_items(""), do: "-"
  defp parse_items("[]"), do: "-"

  defp parse_items(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, items} when is_list(items) ->
        items
        |> Enum.map(fn i ->
          name = i["name"] || "?"
          qty = i["quantity"] || 1
          cat = i["category"]
          if cat && cat != "", do: "#{qty}x #{name} (#{cat})", else: "#{qty}x #{name}"
        end)
        |> Enum.join(", ")

      _ ->
        "-"
    end
  end

  defp parse_items(_), do: "-"

  defp utm_tags(assigns) do
    values = List.wrap(assigns[:values] || []) |> Enum.reject(&(&1 == "" || is_nil(&1)))
    assigns = assign(assigns, :values, values)

    ~H"""
    <div :if={@values != []}>
      <dt class="text-xs font-medium text-gray-500">{@label}</dt>
      <dd class="mt-0.5 flex flex-wrap gap-1">
        <span
          :for={v <- @values}
          class="px-2 py-0.5 rounded text-xs bg-indigo-50 text-indigo-700"
        >
          {v}
        </span>
      </dd>
    </div>
    """
  end

  defp click_platform_label("google_ads"), do: "Google Ads"
  defp click_platform_label("bing_ads"), do: "Microsoft Ads"
  defp click_platform_label("meta_ads"), do: "Meta Ads"
  defp click_platform_label("pinterest_ads"), do: "Pinterest"
  defp click_platform_label("reddit_ads"), do: "Reddit"
  defp click_platform_label("tiktok_ads"), do: "TikTok"
  defp click_platform_label("twitter_ads"), do: "X / Twitter"
  defp click_platform_label("linkedin_ads"), do: "LinkedIn"
  defp click_platform_label("snapchat_ads"), do: "Snapchat"
  defp click_platform_label(other), do: other || "Unknown"

  defp click_platform_class("google_ads"), do: "bg-blue-100 text-blue-800"
  defp click_platform_class("bing_ads"), do: "bg-amber-100 text-amber-800"
  defp click_platform_class("meta_ads"), do: "bg-purple-100 text-purple-800"
  defp click_platform_class("pinterest_ads"), do: "bg-red-100 text-red-800"
  defp click_platform_class("reddit_ads"), do: "bg-orange-100 text-orange-800"
  defp click_platform_class("tiktok_ads"), do: "bg-gray-200 text-gray-900"
  defp click_platform_class("twitter_ads"), do: "bg-sky-100 text-sky-800"
  defp click_platform_class("linkedin_ads"), do: "bg-blue-100 text-blue-900"
  defp click_platform_class("snapchat_ads"), do: "bg-yellow-100 text-yellow-800"
  defp click_platform_class(_), do: "bg-gray-100 text-gray-800"
end
