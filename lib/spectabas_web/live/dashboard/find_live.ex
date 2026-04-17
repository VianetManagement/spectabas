defmodule SpectabasWeb.Dashboard.FindLive do
  use SpectabasWeb, :live_view

  @moduledoc "Search across visitors, events, and transactions for a site."

  alias Spectabas.{Accounts, Sites, ClickHouse}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Spectabas.TypeHelpers
  import Ecto.Query

  @search_types [
    {"email", "Email Address"},
    {"ip", "IP Address"},
    {"visitor_id", "Visitor / Cookie ID"},
    {"user_id", "User ID"},
    {"order_id", "Order ID"},
    {"url", "URL Path (contains)"},
    {"referrer", "Referrer Domain"},
    {"utm_campaign", "UTM Campaign"},
    {"asn_org", "ASN / Organization"}
  ]

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Find - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:search_types, @search_types)
       |> assign(:search_type, "email")
       |> assign(:query, "")
       |> assign(:results, nil)}
    end
  end

  @impl true
  def handle_event("search", %{"type" => type, "q" => q}, socket) do
    q = String.trim(q)

    if q == "" do
      {:noreply, assign(socket, :results, nil)}
    else
      results = do_search(socket.assigns.site, type, q)

      {:noreply,
       socket
       |> assign(:search_type, type)
       |> assign(:query, q)
       |> assign(:results, results)}
    end
  end

  def handle_event("change_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :search_type, type)}
  end

  # --- Search functions ---

  # Email: deduplicate by email — pick the most recently seen visitor,
  # merge all known IPs across duplicates
  defp do_search(site, "email", q) do
    q = String.downcase(q)

    visitors =
      Spectabas.Repo.all(
        from(v in Spectabas.Visitors.Visitor,
          where: v.site_id == ^site.id and like(v.email, ^"%#{escape_like(q)}%"),
          order_by: [desc: v.last_seen_at],
          limit: 200
        )
      )

    # Group by email, keep most recent, merge IPs
    deduped =
      visitors
      |> Enum.group_by(& &1.email)
      |> Enum.map(fn {_email, dupes} ->
        primary = hd(dupes)
        all_ips = dupes |> Enum.flat_map(&(&1.known_ips || [])) |> Enum.uniq()

        first_seen =
          dupes
          |> Enum.map(& &1.first_seen_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.min(DateTime, fn -> nil end)

        %{primary | known_ips: all_ips, first_seen_at: first_seen || primary.first_seen_at}
      end)
      |> Enum.sort_by(& &1.last_seen_at, {:desc, DateTime})

    %{type: :visitors, rows: deduped}
  end

  # IP: multiple visitors at same IP is expected (household, office) — keep separate
  defp do_search(site, "ip", q) do
    visitors =
      Spectabas.Repo.all(
        from(v in Spectabas.Visitors.Visitor,
          where: v.site_id == ^site.id and (v.last_ip == ^q or ^q in v.known_ips),
          order_by: [desc: v.last_seen_at],
          limit: 50
        )
      )

    %{type: :visitors, rows: visitors}
  end

  defp do_search(site, "visitor_id", q) do
    visitors =
      Spectabas.Repo.all(
        from(v in Spectabas.Visitors.Visitor,
          where: v.site_id == ^site.id and (v.cookie_id == ^q or v.id == ^q),
          limit: 10
        )
      )

    %{type: :visitors, rows: visitors}
  end

  # User ID: deduplicate by user_id (same logic as email)
  defp do_search(site, "user_id", q) do
    visitors =
      Spectabas.Repo.all(
        from(v in Spectabas.Visitors.Visitor,
          where: v.site_id == ^site.id and v.user_id == ^q,
          order_by: [desc: v.last_seen_at],
          limit: 100
        )
      )

    deduped =
      visitors
      |> Enum.group_by(& &1.user_id)
      |> Enum.map(fn {_uid, dupes} ->
        primary = hd(dupes)
        all_ips = dupes |> Enum.flat_map(&(&1.known_ips || [])) |> Enum.uniq()

        first_seen =
          dupes
          |> Enum.map(& &1.first_seen_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.min(DateTime, fn -> nil end)

        %{primary | known_ips: all_ips, first_seen_at: first_seen || primary.first_seen_at}
      end)

    %{type: :visitors, rows: deduped}
  end

  defp do_search(site, "order_id", q) do
    sql = """
    SELECT order_id, visitor_id, revenue, currency, timestamp
    FROM ecommerce_events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND order_id = #{ClickHouse.param(q)}
    ORDER BY timestamp DESC
    LIMIT 10
    """

    rows =
      case ClickHouse.query(sql) do
        {:ok, r} -> r
        _ -> []
      end

    %{type: :orders, rows: rows}
  end

  defp do_search(site, "url", q) do
    sql = """
    SELECT
      url_path,
      countIf(event_type = 'pageview') AS pageviews,
      uniq(visitor_id) AS visitors,
      min(timestamp) AS first_seen,
      max(timestamp) AS last_seen
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND url_path LIKE #{ClickHouse.param("%" <> q <> "%")}
      AND ip_is_bot = 0
      AND timestamp >= now() - INTERVAL 30 DAY
    GROUP BY url_path
    ORDER BY pageviews DESC
    LIMIT 50
    """

    rows =
      case ClickHouse.query(sql) do
        {:ok, r} -> r
        _ -> []
      end

    %{type: :pages, rows: rows}
  end

  defp do_search(site, "referrer", q) do
    sql = """
    SELECT
      referrer_domain,
      countIf(event_type = 'pageview') AS pageviews,
      uniq(visitor_id) AS visitors
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND referrer_domain LIKE #{ClickHouse.param("%" <> escape_like(q) <> "%")}
      AND ip_is_bot = 0
      AND timestamp >= now() - INTERVAL 30 DAY
    GROUP BY referrer_domain
    ORDER BY pageviews DESC
    LIMIT 50
    """

    rows =
      case ClickHouse.query(sql) do
        {:ok, r} -> r
        _ -> []
      end

    %{type: :referrers, rows: rows}
  end

  defp do_search(site, "utm_campaign", q) do
    sql = """
    SELECT
      campaign,
      countIf(event_type = 'pageview') AS pageviews,
      uniq(visitor_id) AS visitors,
      uniq(session_id) AS sessions
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND campaign LIKE #{ClickHouse.param("%" <> escape_like(q) <> "%")}
      AND ip_is_bot = 0
      AND timestamp >= now() - INTERVAL 30 DAY
    GROUP BY campaign
    ORDER BY pageviews DESC
    LIMIT 50
    """

    rows =
      case ClickHouse.query(sql) do
        {:ok, r} -> r
        _ -> []
      end

    %{type: :campaigns, rows: rows}
  end

  defp do_search(site, "asn_org", q) do
    sql = """
    SELECT
      ip_org,
      ip_asn,
      uniq(visitor_id) AS visitors,
      countIf(event_type = 'pageview') AS pageviews
    FROM events
    WHERE site_id = #{ClickHouse.param(site.id)}
      AND ip_org LIKE #{ClickHouse.param("%" <> escape_like(q) <> "%")}
      AND ip_is_bot = 0
      AND timestamp >= now() - INTERVAL 30 DAY
    GROUP BY ip_org, ip_asn
    ORDER BY visitors DESC
    LIMIT 50
    """

    rows =
      case ClickHouse.query(sql) do
        {:ok, r} -> r
        _ -> []
      end

    %{type: :orgs, rows: rows}
  end

  defp do_search(_site, _type, _q), do: %{type: :empty, rows: []}

  defp escape_like(s), do: s |> String.replace("%", "\\%") |> String.replace("_", "\\_")

  # --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Find"
      page_description="Search across visitors, events, and transactions."
      active="find"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-gray-900">Find</h1>
          <p class="text-sm text-gray-500 mt-1">Search visitors, pages, orders, and more</p>
        </div>

        <form phx-submit="search" class="bg-white rounded-lg shadow p-6 mb-8">
          <div class="flex flex-col sm:flex-row gap-3">
            <select
              name="type"
              phx-change="change_type"
              class="text-sm border-gray-300 rounded-lg px-3 py-2 sm:w-56"
            >
              <option
                :for={{val, label} <- @search_types}
                value={val}
                selected={val == @search_type}
              >
                {label}
              </option>
            </select>
            <input
              type="text"
              name="q"
              value={@query}
              placeholder={placeholder_for(@search_type)}
              class="flex-1 text-sm border-gray-300 rounded-lg px-3 py-2"
              autofocus
            />
            <button
              type="submit"
              class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
            >
              Search
            </button>
          </div>
        </form>

        <div :if={@results && @results.rows == []} class="bg-white rounded-lg shadow p-12 text-center">
          <p class="text-gray-500">No results found.</p>
        </div>

        <%!-- Visitor results --%>
        <div
          :if={@results && @results.type == :visitors && @results.rows != []}
          class="bg-white rounded-lg shadow overflow-x-auto"
        >
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Visitors ({length(@results.rows)})</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">Email</th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  User ID
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Last IP
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  First Seen
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Last Seen
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <.link
                :for={v <- @results.rows}
                navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{v.id}"}
                class="table-row hover:bg-indigo-50 cursor-pointer transition-colors"
              >
                <td class="px-4 py-3 text-sm text-gray-900">{v.email || "—"}</td>
                <td class="px-4 py-3 text-sm text-gray-600 font-mono text-xs">{v.user_id || "—"}</td>
                <td class="px-4 py-3 text-sm text-gray-600 font-mono text-xs">{v.last_ip || "—"}</td>
                <td class="px-4 py-3 text-sm text-gray-500">{format_dt(v.first_seen_at)}</td>
                <td class="px-4 py-3 text-sm text-gray-500">{format_dt(v.last_seen_at)}</td>
              </.link>
            </tbody>
          </table>
        </div>

        <%!-- Order results --%>
        <div
          :if={@results && @results.type == :orders && @results.rows != []}
          class="bg-white rounded-lg shadow overflow-x-auto"
        >
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Orders ({length(@results.rows)})</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Order ID
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Revenue
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Currency
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Timestamp
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for o <- @results.rows do %>
                <.link
                  :if={o["visitor_id"] != ""}
                  navigate={~p"/dashboard/sites/#{@site.id}/visitors/#{o["visitor_id"]}"}
                  class="table-row hover:bg-indigo-50 cursor-pointer transition-colors"
                >
                  <td class="px-4 py-3 text-sm font-mono text-gray-900">{o["order_id"]}</td>
                  <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {o["revenue"]}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600">{o["currency"]}</td>
                  <td class="px-4 py-3 text-sm text-gray-500">{o["timestamp"]}</td>
                </.link>
                <tr :if={o["visitor_id"] == ""} class="hover:bg-gray-50">
                  <td class="px-4 py-3 text-sm font-mono text-gray-900">{o["order_id"]}</td>
                  <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                    {o["revenue"]}
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600">{o["currency"]}</td>
                  <td class="px-4 py-3 text-sm text-gray-500">{o["timestamp"]}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <%!-- Page results --%>
        <div
          :if={@results && @results.type == :pages && @results.rows != []}
          class="bg-white rounded-lg shadow overflow-x-auto"
        >
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Pages ({length(@results.rows)})</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  URL Path
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Pageviews
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <.link
                :for={p <- @results.rows}
                navigate={~p"/dashboard/sites/#{@site.id}/pages?filter=#{p["url_path"]}"}
                class="table-row hover:bg-indigo-50 cursor-pointer transition-colors"
              >
                <td
                  class="px-4 py-3 text-sm font-mono text-gray-900 truncate max-w-md"
                  title={p["url_path"]}
                >
                  {p["url_path"]}
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(p["pageviews"])}
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(p["visitors"])}
                </td>
              </.link>
            </tbody>
          </table>
        </div>

        <%!-- Referrer results --%>
        <div
          :if={@results && @results.type == :referrers && @results.rows != []}
          class="bg-white rounded-lg shadow overflow-x-auto"
        >
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Referrers ({length(@results.rows)})</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Domain
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Pageviews
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <.link
                :for={r <- @results.rows}
                navigate={~p"/dashboard/sites/#{@site.id}/sources?filter=#{r["referrer_domain"]}"}
                class="table-row hover:bg-indigo-50 cursor-pointer transition-colors"
              >
                <td class="px-4 py-3 text-sm text-gray-900">{r["referrer_domain"]}</td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(r["pageviews"])}
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(r["visitors"])}
                </td>
              </.link>
            </tbody>
          </table>
        </div>

        <%!-- Campaign results --%>
        <div
          :if={@results && @results.type == :campaigns && @results.rows != []}
          class="bg-white rounded-lg shadow overflow-x-auto"
        >
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Campaigns ({length(@results.rows)})</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Campaign
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Pageviews
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Sessions
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <.link
                :for={c <- @results.rows}
                navigate={~p"/dashboard/sites/#{@site.id}/campaigns?filter=#{c["campaign"]}"}
                class="table-row hover:bg-indigo-50 cursor-pointer transition-colors"
              >
                <td class="px-4 py-3 text-sm text-gray-900">{c["campaign"]}</td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(c["pageviews"])}
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(c["visitors"])}
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(c["sessions"])}
                </td>
              </.link>
            </tbody>
          </table>
        </div>

        <%!-- Organization results --%>
        <div
          :if={@results && @results.type == :orgs && @results.rows != []}
          class="bg-white rounded-lg shadow overflow-x-auto"
        >
          <div class="px-6 py-4 border-b border-gray-100">
            <h2 class="font-semibold text-gray-900">Organizations ({length(@results.rows)})</h2>
          </div>
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">
                  Organization
                </th>
                <th class="px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase">ASN</th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Visitors
                </th>
                <th class="px-4 py-2 text-right text-xs font-medium text-gray-500 uppercase">
                  Pageviews
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <.link
                :for={o <- @results.rows}
                navigate={~p"/dashboard/sites/#{@site.id}/network?filter=#{o["ip_org"]}"}
                class="table-row hover:bg-indigo-50 cursor-pointer transition-colors"
              >
                <td class="px-4 py-3 text-sm text-gray-900">{o["ip_org"]}</td>
                <td class="px-4 py-3 text-sm text-gray-600 font-mono">{o["ip_asn"]}</td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(o["visitors"])}
                </td>
                <td class="px-4 py-3 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(o["pageviews"])}
                </td>
              </.link>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp placeholder_for("email"), do: "user@example.com"
  defp placeholder_for("ip"), do: "192.168.1.1"
  defp placeholder_for("visitor_id"), do: "cookie or visitor UUID"
  defp placeholder_for("user_id"), do: "your app's user ID"
  defp placeholder_for("order_id"), do: "ORD-123 or pi_..."
  defp placeholder_for("url"), do: "/pricing, /signup..."
  defp placeholder_for("referrer"), do: "google.com"
  defp placeholder_for("utm_campaign"), do: "summer-sale"
  defp placeholder_for("asn_org"), do: "Comcast, Google..."
  defp placeholder_for(_), do: "Search..."

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(_), do: "—"
end
