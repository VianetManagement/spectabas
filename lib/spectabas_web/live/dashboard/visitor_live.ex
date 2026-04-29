defmodule SpectabasWeb.Dashboard.VisitorLive do
  use SpectabasWeb, :live_view

  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers

  alias Spectabas.{Accounts, Sites, Visitors, Analytics, Goals}
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
        |> assign(:completed_goals, nil)
        |> assign(:editing_notes, false)
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

    # Goal completions — single CH query, match in Elixir
    Task.start(fn ->
      goals = Goals.list_goals(site)

      completed =
        if goals == [] do
          []
        else
          case Spectabas.ClickHouse.query("""
               SELECT
                 groupUniqArray(url_path) AS pages,
                 groupUniqArray(event_name) AS events
               FROM events
               WHERE site_id = #{Spectabas.ClickHouse.param(site.id)}
                 AND visitor_id = #{Spectabas.ClickHouse.param(visitor_id)}
                 AND ip_is_bot = 0
               """) do
            {:ok, [row]} ->
              pages = row["pages"] || []
              events = row["events"] || []

              Enum.filter(goals, fn goal ->
                case goal.goal_type do
                  "pageview" ->
                    path = goal.page_path || ""
                    Enum.any?(pages, fn p -> String.starts_with?(p, path) end)

                  "custom_event" ->
                    goal.event_name in events

                  "click_element" ->
                    "_click" in events

                  _ ->
                    false
                end
              end)

            _ ->
              []
          end
        end

      send(lv_pid, {:deferred_result, :completed_goals, completed})
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
          scraper_webhook_score: nil,
          scraper_manual_flag: false
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

  def handle_event("send_webhook", _params, socket) do
    site = socket.assigns.site
    visitor = socket.assigns.visitor

    # Use the current scraper score, or 0 if not yet computed
    score = if socket.assigns.scraper, do: socket.assigns.scraper.score, else: 0
    signals = if socket.assigns.scraper, do: socket.assigns.scraper.signals, else: []

    score_result = %{score: score, signals: signals}

    case Spectabas.Webhooks.ScraperWebhook.send_flag(site, visitor, score_result, 0) do
      {:ok, _} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        visitor
        |> Spectabas.Visitors.Visitor.changeset(%{
          scraper_webhook_sent_at: now,
          scraper_webhook_score: score
        })
        |> Spectabas.Repo.update()

        {:noreply,
         socket
         |> assign(:visitor, Spectabas.Repo.get!(Spectabas.Visitors.Visitor, visitor.id))
         |> put_flash(:info, "Webhook sent with score #{score}.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to send webhook.")}
    end
  end

  def handle_event("mark_scraper", _params, socket) do
    site = socket.assigns.site
    visitor = socket.assigns.visitor

    score_result = %{score: 100, signals: [:manual_flag]}

    # Send webhook with score 100
    result =
      if site.scraper_webhook_enabled && site.scraper_webhook_url do
        Spectabas.Webhooks.ScraperWebhook.send_flag(site, visitor, score_result, 0)
      else
        {:ok, %{status: "no webhook configured"}}
      end

    case result do
      {:ok, _} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        visitor
        |> Spectabas.Visitors.Visitor.changeset(%{
          scraper_webhook_sent_at: now,
          scraper_webhook_score: 100,
          scraper_manual_flag: true,
          scraper_whitelisted: false
        })
        |> Spectabas.Repo.update()

        {:noreply,
         socket
         |> assign(:visitor, Spectabas.Repo.get!(Spectabas.Visitors.Visitor, visitor.id))
         |> assign(:scraper, %{
           score: 100,
           signals: [:manual_flag],
           verdict: :certain,
           unique_pages: 0,
           ip_count: 0
         })
         |> put_flash(:info, "Visitor marked as scraper (score 100) — webhook sent.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to send webhook.")}
    end
  end

  # Whitelist this visitor: clear all scraper flags AND set scraper_whitelisted = true
  # so the 15-min worker won't re-flag them no matter how high their auto score gets.
  # Also sends a deactivation webhook if they're currently flagged so external systems
  # learn they're not a scraper anymore. If the visitor has an email, propagate the
  # whitelist to every other visitor record on this site with the same email — so
  # the same human stays exempt across cookie clears / new devices.
  def handle_event("whitelist_scraper", _params, socket) do
    site = socket.assigns.site
    visitor = socket.assigns.visitor

    if site.scraper_webhook_enabled && site.scraper_webhook_url &&
         visitor.scraper_webhook_sent_at do
      _ = Spectabas.Webhooks.ScraperWebhook.send_deactivate(site, visitor)
    end

    visitor
    |> Spectabas.Visitors.Visitor.changeset(%{
      scraper_webhook_sent_at: nil,
      scraper_webhook_score: nil,
      scraper_manual_flag: false,
      scraper_whitelisted: true
    })
    |> Spectabas.Repo.update()

    propagated = Spectabas.Visitors.propagate_whitelist_by_email(site.id, visitor, true)

    flash =
      cond do
        propagated == 0 ->
          "Visitor whitelisted — they will not be auto-flagged again."

        propagated == 1 ->
          "Visitor whitelisted (also applied to 1 other record with the same email)."

        true ->
          "Visitor whitelisted (also applied to #{propagated} other records with the same email)."
      end

    {:noreply,
     socket
     |> assign(:visitor, Spectabas.Repo.get!(Spectabas.Visitors.Visitor, visitor.id))
     |> assign(:status, :whitelisted)
     |> put_flash(:info, flash)}
  end

  # Reverse of whitelist — re-enable automatic scraper detection for this visitor
  # and any sibling records that share the same email (kept consistent with the
  # forward action so toggles are reversible).
  def handle_event("unwhitelist_scraper", _params, socket) do
    site = socket.assigns.site
    visitor = socket.assigns.visitor

    visitor
    |> Spectabas.Visitors.Visitor.changeset(%{scraper_whitelisted: false})
    |> Spectabas.Repo.update()

    _ = Spectabas.Visitors.propagate_whitelist_by_email(site.id, visitor, false)

    {:noreply,
     socket
     |> assign(:visitor, Spectabas.Repo.get!(Spectabas.Visitors.Visitor, visitor.id))
     |> put_flash(:info, "Whitelist removed. Automatic scraper detection re-enabled.")}
  end

  def handle_event("toggle_notes", _params, socket) do
    {:noreply, assign(socket, :editing_notes, !socket.assigns.editing_notes)}
  end

  def handle_event("save_notes", %{"notes" => notes}, socket) do
    changeset = Visitors.Visitor.changeset(socket.assigns.visitor, %{notes: notes})

    case Spectabas.Repo.update(changeset) do
      {:ok, visitor} ->
        {:noreply, socket |> assign(visitor: visitor, editing_notes: false)}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to save notes.")}
    end
  end

  def handle_event("export_profile", _params, socket) do
    visitor = socket.assigns.visitor
    profile = socket.assigns.profile

    data = %{
      visitor_id: visitor.id,
      email: visitor.email,
      user_id: visitor.user_id,
      external_id: visitor.external_id,
      notes: visitor.notes,
      first_seen: profile["first_seen"],
      last_seen: profile["last_seen"],
      total_pageviews: profile["total_pageviews"],
      total_sessions: profile["total_sessions"],
      browser: profile["browser"],
      os: profile["os"],
      device_type: profile["device_type"],
      country: profile["country"],
      region: profile["region"],
      city: profile["city"],
      original_referrer: profile["original_referrer"],
      utm_sources: profile["utm_sources"],
      utm_campaigns: profile["utm_campaigns"]
    }

    json = Jason.encode!(data, pretty: true)
    short_id = String.slice(to_string(visitor.id), 0, 8)
    filename = "visitor_#{short_id}_#{Date.to_iso8601(Date.utc_today())}.json"

    {:noreply,
     push_event(socket, "download", %{filename: filename, content: json, mime: "application/json"})}
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
          <div class="flex items-center justify-between mt-2">
            <div class="flex items-center gap-3 flex-wrap">
              <h1 class="text-2xl font-bold text-gray-900">Visitor Profile</h1>
              <span
                :if={@visitor.scraper_manual_flag or @visitor.scraper_webhook_score == 100}
                class="inline-flex items-center gap-1.5 px-3 py-1 rounded-lg text-sm font-semibold bg-red-100 text-red-800 border border-red-200"
              >
                <.icon name="hero-shield-exclamation" class="w-5 h-5" /> Marked as Scraper
              </span>
              <span
                :if={@visitor.scraper_whitelisted}
                class="inline-flex items-center gap-1.5 px-3 py-1 rounded-lg text-sm font-semibold bg-emerald-100 text-emerald-800 border border-emerald-200"
                title="This visitor is permanently whitelisted from scraper detection."
              >
                <.icon name="hero-shield-check" class="w-5 h-5" /> Whitelisted
              </span>
            </div>
            <button
              phx-click="export_profile"
              class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-indigo-700 bg-indigo-50 hover:bg-indigo-100 border border-indigo-200"
            >
              <.icon name="hero-arrow-down-tray" class="w-3.5 h-3.5 mr-1.5" /> Export JSON
            </button>
          </div>
        </div>

        <%!-- Webhook Status Banner --%>
        <.webhook_status_banner
          visitor={@visitor}
          webhook_deliveries={@webhook_deliveries}
          site={@site}
        />

        <%!-- Top stats row --%>
        <div class={"grid grid-cols-1 sm:grid-cols-2 gap-4 mb-6 " <> if(@ltv, do: "md:grid-cols-6", else: "md:grid-cols-5")}>
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

        <%!-- Goal Completion Badges --%>
        <div
          :if={@completed_goals != nil && @completed_goals != []}
          class="mb-6 flex flex-wrap gap-2 items-center"
        >
          <span class="text-xs font-medium text-gray-500 uppercase">Goals completed:</span>
          <span
            :for={goal <- @completed_goals}
            class={[
              "inline-flex items-center px-2 py-0.5 rounded-lg text-xs font-medium",
              case goal.goal_type do
                "pageview" -> "bg-blue-100 text-blue-800"
                "custom_event" -> "bg-purple-100 text-purple-800"
                "click_element" -> "bg-green-100 text-green-800"
                _ -> "bg-gray-100 text-gray-800"
              end
            ]}
          >
            {goal.name}
          </span>
        </div>

        <%!-- Notes --%>
        <div class="bg-white rounded-lg shadow mb-6 px-5 py-4">
          <div class="flex items-center justify-between mb-2">
            <h3 class="text-xs font-semibold text-gray-500 uppercase">Notes</h3>
            <button
              :if={!@editing_notes}
              phx-click="toggle_notes"
              class="text-xs text-indigo-600 hover:text-indigo-800"
            >
              {if @visitor.notes && @visitor.notes != "", do: "Edit", else: "Add"}
            </button>
          </div>
          <%= if @editing_notes do %>
            <form phx-submit="save_notes" class="space-y-2">
              <textarea
                name="notes"
                rows="3"
                class="w-full text-sm rounded-lg border-gray-300 focus:border-indigo-500 focus:ring-indigo-500"
                placeholder="Add a note about this visitor..."
              >{@visitor.notes}</textarea>
              <div class="flex items-center gap-2">
                <button
                  type="submit"
                  class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
                >
                  Save
                </button>
                <button
                  type="button"
                  phx-click="toggle_notes"
                  class="text-xs text-gray-500 hover:text-gray-700"
                >
                  Cancel
                </button>
              </div>
            </form>
          <% else %>
            <p class={[
              "text-sm",
              if(@visitor.notes && @visitor.notes != "",
                do: "text-gray-700",
                else: "text-gray-400 italic"
              )
            ]}>
              {if @visitor.notes && @visitor.notes != "", do: @visitor.notes, else: "No notes yet."}
            </p>
          <% end %>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-6">
          <%!-- Identity & Device --%>
          <div class="bg-white rounded-lg shadow p-5">
            <h3 class="text-sm font-semibold text-gray-700 mb-3 uppercase">Identity & Device</h3>
            <dl class="space-y-2 text-sm">
              <.field
                label="Visitor ID"
                value={to_string(@visitor.id)}
                mono={true}
                copy={to_string(@visitor.id)}
              />
              <.field :if={@visitor.email} label="Email" value={@visitor.email} copy={@visitor.email} />
              <.field
                :if={@visitor.user_id}
                label="User ID"
                value={@visitor.user_id}
                mono={true}
                copy={@visitor.user_id}
              />
              <.field
                :if={@visitor.external_id}
                label="External ID"
                value={@visitor.external_id}
                mono={true}
                copy={@visitor.external_id}
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
              <.field
                :if={@visitor.cookie_id}
                label="SAB Cookie"
                value={@visitor.cookie_id}
                mono={true}
                copy={@visitor.cookie_id}
                ext_link={"https://trustadmiral.com/scraper-defense?_target%5B%5D=sab_cookie&sab_cookie=#{@visitor.cookie_id}"}
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
              <div
                :if={
                  @ip_info && to_string(@ip_info["ip_lat"]) != "0" &&
                    to_string(@ip_info["ip_lat"]) != "" && @ip_info["ip_lat"] != nil
                }
                class="pt-3 border-t border-gray-100"
              >
                <a
                  href={"https://www.openstreetmap.org/?mlat=#{@ip_info["ip_lat"]}&mlon=#{@ip_info["ip_lon"]}&zoom=12"}
                  target="_blank"
                  rel="noopener"
                  class="inline-flex items-center gap-1.5 text-xs text-indigo-600 hover:text-indigo-800"
                >
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="w-3.5 h-3.5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                    stroke-width="2"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M15 10.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
                    />
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M19.5 10.5c0 7.142-7.5 11.25-7.5 11.25S4.5 17.642 4.5 10.5a7.5 7.5 0 0 1 15 0Z"
                    />
                  </svg>
                  View on map ({@ip_info["ip_lat"]}, {@ip_info["ip_lon"]})
                </a>
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
                  <span class="text-xs font-mono text-gray-500 truncate max-w-[100px] sm:max-w-[200px]">
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
            <div :if={@ip_info} class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-4 mb-4">
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
              <table class="min-w-full divide-y divide-gray-200 text-xs sm:text-sm">
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
            <table class="min-w-full divide-y divide-gray-200 text-xs sm:text-sm">
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
                    <span class="flex items-center gap-1">
                      <.link
                        navigate={~p"/dashboard/sites/#{@site.id}/ip/#{ip["ip_address"]}"}
                        class="font-mono text-xs text-indigo-600 hover:text-indigo-800"
                      >
                        {ip["ip_address"]}
                      </.link>
                      <button
                        id={"copy-ip-#{ip["ip_address"] |> String.replace(~r/[^a-zA-Z0-9]/, "-")}"}
                        phx-hook="CopyClipboard"
                        data-copy={ip["ip_address"]}
                        title="Copy to clipboard"
                        class="text-gray-400 hover:text-indigo-600 cursor-pointer"
                      >
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          class="w-3 h-3"
                          fill="none"
                          viewBox="0 0 24 24"
                          stroke="currentColor"
                          stroke-width="2"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            d="M15.666 3.888A2.25 2.25 0 0 0 13.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 0 1-.75.75H9.75a.75.75 0 0 1-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 0 1-2.25 2.25H6.75A2.25 2.25 0 0 1 4.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 0 1 1.927-.184"
                          />
                        </svg>
                      </button>
                    </span>
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

        <%!-- Page Flow --%>
        <.loading_section loaded={@timeline != nil}>
          <div :if={@timeline != nil && @timeline != []} class="bg-white rounded-lg shadow mb-6">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="text-sm font-semibold text-gray-700">Page Flow</h3>
            </div>
            <div class="px-5 py-3">
              <div class="flex flex-wrap items-center gap-1">
                <%= for {event, idx} <- @timeline |> Enum.filter(& &1["event_type"] == "pageview") |> Enum.take(20) |> Enum.with_index() do %>
                  <span :if={idx > 0} class="text-gray-300 text-xs">&rarr;</span>
                  <span
                    class="inline-flex px-2 py-0.5 rounded bg-blue-50 text-xs font-mono text-blue-700 truncate max-w-[100px] sm:max-w-[160px]"
                    title={event["url_path"]}
                  >
                    {event["url_path"]}
                  </span>
                <% end %>
              </div>
            </div>
          </div>
        </.loading_section>

        <%!-- Session History --%>
        <.loading_section loaded={@sessions != nil}>
          <div :if={@sessions != nil} class="bg-white rounded-lg shadow mb-6">
            <div class="px-5 py-4 border-b border-gray-100">
              <h3 class="text-sm font-semibold text-gray-700">Sessions ({length(@sessions)})</h3>
            </div>
            <table class="min-w-full divide-y divide-gray-200 text-xs sm:text-sm">
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
          <table class="min-w-full divide-y divide-gray-200 text-xs sm:text-sm">
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
          <table class="min-w-full divide-y divide-gray-200 text-xs sm:text-sm">
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
    # Determine current webhook state from visitor record + deliveries.
    # Whitelisted always wins so the action buttons make sense.
    status =
      cond do
        assigns.visitor.scraper_whitelisted -> :whitelisted
        true -> webhook_status(assigns.visitor, assigns.webhook_deliveries)
      end

    assigns = assign(assigns, :status, status)

    ~H"""
    <%= case @status do %>
      <% :whitelisted -> %>
        <div class="mb-6 rounded-lg border border-emerald-200 bg-emerald-50 p-4 flex items-center gap-3">
          <div class="flex-shrink-0">
            <.icon name="hero-shield-check" class="w-6 h-6 text-emerald-600" />
          </div>
          <div class="flex-1">
            <h3 class="text-sm font-semibold text-emerald-800">Whitelisted from scraper detection</h3>
            <p class="text-xs text-emerald-700 mt-0.5">
              This visitor will not be auto-flagged by the scraper webhook scan, regardless of their behavior. To re-enable detection for this visitor, click "Remove from whitelist".
            </p>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <button
              phx-click="unwhitelist_scraper"
              data-confirm="Re-enable automatic scraper detection for this visitor?"
              class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-emerald-700 border border-emerald-300 hover:bg-emerald-100 shadow-sm"
            >
              Remove from whitelist
            </button>
          </div>
        </div>
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
              phx-click="mark_scraper"
              data-confirm="Mark as scraper (score 100) and send webhook?"
              class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-white bg-red-600 hover:bg-red-700 shadow-sm"
            >
              Mark as Scraper
            </button>
            <button
              phx-click="send_webhook"
              data-confirm="Re-send scraper webhook with current score?"
              class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-amber-700 border border-amber-300 hover:bg-amber-50 shadow-sm"
            >
              Re-send
            </button>
            <button
              phx-click="unflag_scraper"
              data-confirm="Clear the scraper flag and send a deactivation webhook. Note: this is NOT permanent — they may be re-flagged if their behavior crosses the watching threshold again. Continue?"
              class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-white bg-green-600 hover:bg-green-700 shadow-sm"
            >
              Unflag
            </button>
            <button
              phx-click="whitelist_scraper"
              data-confirm="Permanently whitelist this visitor. They will never be auto-flagged again, regardless of behavior. Continue?"
              class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-emerald-700 border border-emerald-300 hover:bg-emerald-50 shadow-sm"
            >
              Whitelist
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
          <.death_star_spinner class="w-4 h-4 text-gray-400" />
          <span class="text-xs text-gray-500">Loading webhook status...</span>
        </div>
      <% _ -> %>
        <%!-- Not flagged — show action buttons --%>
        <div class="mb-6 flex items-center gap-2">
          <button
            phx-click="send_webhook"
            data-confirm="Send scraper webhook with the current score?"
            class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-white bg-amber-600 hover:bg-amber-700 shadow-sm"
          >
            Send Webhook
          </button>
          <button
            phx-click="mark_scraper"
            data-confirm="This will permanently mark this visitor as a scraper (score 100) and send the webhook. Continue?"
            class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-white bg-red-600 hover:bg-red-700 shadow-sm"
          >
            Mark as Scraper
          </button>
          <button
            phx-click="whitelist_scraper"
            data-confirm="Permanently whitelist this visitor from scraper detection. Continue?"
            class="inline-flex items-center px-3 py-1.5 text-xs font-medium rounded-lg text-emerald-700 border border-emerald-300 hover:bg-emerald-50 shadow-sm"
          >
            Whitelist
          </button>
        </div>
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
          <table class="min-w-full divide-y divide-gray-200 text-xs sm:text-sm">
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
    assigns =
      assigns
      |> Map.put_new(:mono, false)
      |> Map.put_new(:copy, nil)
      |> Map.put_new(:ext_link, nil)

    ~H"""
    <div>
      <dt class="text-xs font-medium text-gray-500">{@label}</dt>
      <dd class={[
        "mt-0.5 text-gray-900 flex items-center gap-1.5",
        if(@mono, do: "font-mono text-xs", else: "")
      ]}>
        <span>{@value}</span>
        <button
          :if={@copy}
          id={"copy-#{String.replace(@label, " ", "-") |> String.downcase()}"}
          phx-hook="CopyClipboard"
          data-copy={@copy}
          title="Copy to clipboard"
          class="text-gray-400 hover:text-indigo-600 cursor-pointer shrink-0"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-3.5 h-3.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="2"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M15.666 3.888A2.25 2.25 0 0 0 13.5 2.25h-3c-1.03 0-1.9.693-2.166 1.638m7.332 0c.055.194.084.4.084.612v0a.75.75 0 0 1-.75.75H9.75a.75.75 0 0 1-.75-.75v0c0-.212.03-.418.084-.612m7.332 0c.646.049 1.288.11 1.927.184 1.1.128 1.907 1.077 1.907 2.185V19.5a2.25 2.25 0 0 1-2.25 2.25H6.75A2.25 2.25 0 0 1 4.5 19.5V6.257c0-1.108.806-2.057 1.907-2.185a48.208 48.208 0 0 1 1.927-.184"
            />
          </svg>
        </button>
        <a
          :if={@ext_link}
          href={@ext_link}
          target="_blank"
          rel="noopener"
          title="Open external"
          class="text-gray-400 hover:text-indigo-600 shrink-0"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="w-3.5 h-3.5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="2"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M13.5 6H5.25A2.25 2.25 0 0 0 3 8.25v10.5A2.25 2.25 0 0 0 5.25 21h10.5A2.25 2.25 0 0 0 18 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"
            />
          </svg>
        </a>
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
