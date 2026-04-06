defmodule SpectabasWeb.Dashboard.RevenueAttributionLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Analytics}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.Dashboard.DateHelpers
  import Spectabas.TypeHelpers

  @utm_tabs [
    {"source", "Source"},
    {"medium", "Medium"},
    {"campaign", "Campaign"},
    {"term", "Term"},
    {"content", "Content"}
  ]

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Revenue Attribution - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:date_range, "30d")
       |> assign(:group_by, "source")
       |> assign(:touch, "last")
       |> assign(:utm_tabs, @utm_tabs)
       |> assign(:sort_by, "total_revenue")
       |> assign(:sort_dir, "desc")
       |> load_data()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply, socket |> assign(:date_range, range) |> load_data()}
  end

  def handle_event("change_group", %{"group" => group}, socket) do
    {:noreply, socket |> assign(:group_by, group) |> load_data()}
  end

  def handle_event("change_touch", %{"touch" => touch}, socket) do
    {:noreply, socket |> assign(:touch, touch) |> load_data()}
  end

  def handle_event("sort", %{"col" => col}, socket) do
    {sort_by, sort_dir} =
      socket.assigns |> Map.take([:sort_by, :sort_dir]) |> Map.values() |> List.to_tuple()

    new_dir =
      if col == sort_by do
        if sort_dir == "desc", do: "asc", else: "desc"
      else
        "desc"
      end

    {:noreply,
     socket
     |> assign(:sort_by, col)
     |> assign(:sort_dir, new_dir)
     |> sort_rows()}
  end

  defp load_data(socket) do
    %{site: site, user: user, date_range: range, group_by: group, touch: touch} = socket.assigns
    period = range_to_period(range)

    rows =
      case Analytics.revenue_by_source(site, user, period, group_by: group, touch: touch) do
        {:ok, data} -> data
        _ -> []
      end

    channels =
      case Analytics.revenue_by_channel(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    # Ad spend data
    ad_campaigns =
      case Analytics.ad_spend_by_campaign(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    ad_platforms =
      case Analytics.ad_spend_by_platform(site, user, period) do
        {:ok, data} -> data
        _ -> []
      end

    ad_totals =
      case Analytics.ad_spend_totals(site, user, period) do
        {:ok, [row | _]} -> row
        _ -> %{}
      end

    # Revenue attributed via click IDs (gclid/msclkid/fbclid)
    ad_revenue =
      case Analytics.ad_revenue_by_platform(site, user, period, touch: touch) do
        {:ok, data} -> data
        _ -> []
      end

    # Build spend lookup keyed by campaign_name for merging into rows
    spend_by_campaign = Map.new(ad_campaigns, fn c -> {c["campaign_name"], c} end)

    # Merge ad spend into revenue rows when viewing by campaign
    rows =
      if group == "campaign" do
        Enum.map(rows, fn row ->
          source = row["source"] || ""
          spend_row = Map.get(spend_by_campaign, source, %{})
          spend = parse_float(spend_row["total_spend"])
          revenue = parse_float(row["total_revenue"])
          roas = if spend > 0, do: Float.round(revenue / spend, 2), else: nil

          row
          |> Map.put("ad_spend", spend)
          |> Map.put("ad_clicks", to_num(spend_row["total_clicks"]))
          |> Map.put("ad_impressions", to_num(spend_row["total_impressions"]))
          |> Map.put("roas", roas)
          |> Map.put(
            "cpc",
            if(to_num(spend_row["total_clicks"]) > 0,
              do: Float.round(spend / to_num(spend_row["total_clicks"]), 2),
              else: nil
            )
          )
        end)
      else
        rows
      end

    # Compute totals
    total_revenue =
      Enum.reduce(channels, 0, fn c, acc -> acc + parse_float(c["total_revenue"]) end)

    total_orders =
      Enum.reduce(channels, 0, fn c, acc -> acc + to_num(c["orders"]) end)

    total_visitors =
      Enum.reduce(channels, 0, fn c, acc -> acc + to_num(c["visitors"]) end)

    total_spend = parse_float(ad_totals["total_spend"])

    # Merge spend + click-ID revenue per platform
    revenue_by_plat = Map.new(ad_revenue, fn r -> {r["platform"], r} end)

    ad_platforms_merged =
      Enum.map(ad_platforms, fn p ->
        rev = Map.get(revenue_by_plat, p["platform"], %{})
        spend = parse_float(p["total_spend"])
        revenue = parse_float(rev["total_revenue"])
        roas = if spend > 0 and revenue > 0, do: Float.round(revenue / spend, 2), else: nil

        p
        |> Map.put("attributed_revenue", revenue)
        |> Map.put("attributed_orders", to_num(rev["orders"]))
        |> Map.put("attributed_visitors", to_num(rev["visitors"]))
        |> Map.put("roas", roas)
      end)

    total_ad_revenue =
      Enum.reduce(ad_revenue, 0, fn r, acc -> acc + parse_float(r["total_revenue"]) end)

    total_roas =
      if total_spend > 0 and total_ad_revenue > 0,
        do: Float.round(total_ad_revenue / total_spend, 2),
        else: nil

    has_ad_data = total_spend > 0

    socket
    |> assign(:rows_unsorted, rows)
    |> assign(:rows, rows)
    |> assign(:channels, channels)
    |> assign(:total_revenue, total_revenue)
    |> assign(:total_orders, total_orders)
    |> assign(:total_visitors, total_visitors)
    |> assign(:ad_platforms, ad_platforms_merged)
    |> assign(:total_ad_revenue, total_ad_revenue)
    |> assign(:ad_campaigns, ad_campaigns)
    |> assign(:total_spend, total_spend)
    |> assign(:total_ad_clicks, to_num(ad_totals["total_clicks"]))
    |> assign(:total_ad_impressions, to_num(ad_totals["total_impressions"]))
    |> assign(:total_roas, total_roas)
    |> assign(:has_ad_data, has_ad_data)
    |> sort_rows()
  end

  defp sort_rows(socket) do
    rows = socket.assigns[:rows_unsorted] || socket.assigns[:rows] || []
    sort_by = socket.assigns[:sort_by] || "total_revenue"
    sort_dir = socket.assigns[:sort_dir] || "desc"

    sorted =
      Enum.sort_by(
        rows,
        fn row ->
          val = row[sort_by]

          cond do
            is_nil(val) ->
              0

            is_number(val) ->
              val

            is_binary(val) ->
              case Float.parse(val) do
                {f, _} -> f
                :error -> 0
              end

            true ->
              0
          end
        end,
        if(sort_dir == "asc", do: :asc, else: :desc)
      )

    assign(socket, :rows, sorted)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Revenue Attribution"
      page_description="Which traffic sources generate paying customers."
      active="revenue-attribution"
      live_visitors={0}
    >
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
          <h1 class="text-2xl font-bold text-gray-900">Revenue Attribution</h1>
          <div class="flex gap-2">
            <%!-- First/Last Touch Toggle --%>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={
                  {id, label} <- [
                    {"first", "First Touch"},
                    {"last", "Last Touch"},
                    {"any", "Any Touch"}
                  ]
                }
                phx-click="change_touch"
                phx-value-touch={id}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
                  if(@touch == id,
                    do: "bg-white shadow text-gray-900",
                    else: "text-gray-600 hover:text-gray-900"
                  )
                ]}
              >
                {label}
              </button>
            </nav>
            <%!-- Date Range --%>
            <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
              <button
                :for={r <- [{"7d", "7d"}, {"30d", "30d"}, {"90d", "90d"}]}
                phx-click="change_range"
                phx-value-range={elem(r, 0)}
                class={[
                  "px-2.5 py-1 text-xs font-medium rounded-md",
                  if(@date_range == elem(r, 0),
                    do: "bg-white shadow text-gray-900",
                    else: "text-gray-600 hover:text-gray-900"
                  )
                ]}
              >
                {elem(r, 1)}
              </button>
            </nav>
          </div>
        </div>

        <%!-- Ad Spend Summary (only shown when ad data exists) --%>
        <div :if={@has_ad_data} class="bg-white rounded-lg shadow p-5 mb-6">
          <div class="flex items-start justify-between mb-3">
            <h2 class="text-sm font-semibold text-gray-900">Ad Spend Overview</h2>
            <span class="text-[10px] text-gray-400 max-w-xs text-right leading-tight">
              Spend data from connected ad platforms. Revenue tracked via click IDs (gclid/msclkid/fbclid) on ad traffic.
            </span>
          </div>
          <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
            <div>
              <dt class="text-xs text-gray-500">Total Spend</dt>
              <dd class="text-lg font-bold text-gray-900">
                {Spectabas.Currency.format(@total_spend, @site.currency)}
              </dd>
              <dd class="text-[10px] text-gray-400">from connected platforms</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500">Ad Revenue</dt>
              <dd class="text-lg font-bold text-green-600">
                {Spectabas.Currency.format(@total_ad_revenue, @site.currency)}
              </dd>
              <%= if @total_ad_revenue == 0 do %>
                <dd class="text-[10px] text-amber-500">
                  No click ID conversions yet. Revenue will appear here as visitors who arrive via ad clicks (gclid/msclkid/fbclid) make purchases.
                </dd>
              <% else %>
                <dd class="text-[10px] text-gray-400">from visitors with ad click IDs</dd>
              <% end %>
            </div>
            <div>
              <dt class="text-xs text-gray-500">ROAS</dt>
              <dd class={[
                "text-lg font-bold",
                cond do
                  @total_roas == nil -> "text-gray-400"
                  @total_roas >= 3 -> "text-green-600"
                  @total_roas >= 1 -> "text-yellow-600"
                  true -> "text-red-600"
                end
              ]}>
                {if @total_roas, do: "#{@total_roas}x", else: "--"}
              </dd>
              <dd class="text-[10px] text-gray-400">
                {if @total_roas, do: "ad revenue / ad spend", else: "needs ad revenue data"}
              </dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500">Ad Clicks</dt>
              <dd class="text-lg font-bold text-gray-900">{format_number(@total_ad_clicks)}</dd>
              <dd class="text-[10px] text-gray-400">reported by platform</dd>
            </div>
            <div>
              <dt class="text-xs text-gray-500">Impressions</dt>
              <dd class="text-lg font-bold text-gray-900">{format_number(@total_ad_impressions)}</dd>
              <dd class="text-[10px] text-gray-400">reported by platform</dd>
            </div>
          </div>

          <%!-- How it works hint (shown when no revenue yet) --%>
          <div :if={@total_ad_revenue == 0} class="mt-4 pt-3 border-t border-gray-100">
            <p class="text-xs text-gray-500 leading-relaxed">
              <strong class="text-gray-700">How ROAS tracking works:</strong>
              When a visitor clicks your ad, the platform appends a click ID to the URL (e.g. <code class="text-[10px] bg-gray-100 px-1 rounded">?gclid=abc123</code>).
              Spectabas captures this and tags the visitor. If they later convert, that revenue is attributed to the ad platform.
              Click ID data builds over time as new ad visitors arrive and convert.
            </p>
          </div>

          <%!-- Per-platform summary (compact) --%>
          <div :if={@ad_platforms != []} class="mt-4 pt-3 border-t border-gray-100">
            <div class="flex flex-wrap gap-4">
              <div :for={p <- @ad_platforms} class="flex items-center gap-2 text-sm">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  ad_pill_class(p["platform"])
                ]}>
                  {platform_label(p["platform"])}
                </span>
                <span class="text-gray-500">
                  {Spectabas.Currency.format(p["total_spend"], @site.currency)} spend
                </span>
                <span class="text-gray-400">{format_number(to_num(p["total_clicks"]))} clicks</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Channel Summary Cards --%>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mb-6">
          <div :for={ch <- @channels} class="bg-white rounded-lg shadow p-3">
            <dt class="text-[10px] font-medium text-gray-500 uppercase truncate">
              {ch["channel"]}
            </dt>
            <dd class="mt-0.5 text-lg font-bold text-gray-900">
              {Spectabas.Currency.format(ch["total_revenue"], @site.currency)}
            </dd>
            <dd class="text-xs text-gray-500">
              {to_num(ch["orders"])} orders &middot; {ch["conversion_rate"]}%
            </dd>
          </div>
        </div>

        <div :if={@total_revenue > 0} class="bg-indigo-50 rounded-lg p-3 mb-6 flex gap-6 text-sm">
          <span class="font-medium text-indigo-900">
            Total: {Spectabas.Currency.format(@total_revenue, @site.currency)}
          </span>
          <span class="text-indigo-700">{format_number(@total_orders)} orders</span>
          <span class="text-indigo-700">{format_number(@total_visitors)} visitors</span>
          <span class="text-indigo-700">
            {touch_label(@touch)} attribution
          </span>
        </div>

        <%!-- UTM Dimension Tabs --%>
        <nav class="flex gap-1 bg-gray-100 rounded-lg p-1 mb-6 w-fit">
          <button
            :for={{id, label} <- @utm_tabs}
            phx-click="change_group"
            phx-value-group={id}
            class={[
              "px-3 py-1.5 text-sm font-medium rounded-md",
              if(@group_by == id,
                do: "bg-white shadow text-gray-900",
                else: "text-gray-600 hover:text-gray-900"
              )
            ]}
          >
            {label}
          </button>
        </nav>

        <%!-- Source Table --%>
        <div class="bg-white rounded-lg shadow overflow-x-auto">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <.sort_th
                  col="source"
                  label={String.capitalize(@group_by)}
                  align="left"
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                />
                <.sort_th col="visitors" label="Visitors" sort_by={@sort_by} sort_dir={@sort_dir} />
                <.sort_th col="orders" label="Orders" sort_by={@sort_by} sort_dir={@sort_dir} />
                <.sort_th col="total_revenue" label="Revenue" sort_by={@sort_by} sort_dir={@sort_dir} />
                <.sort_th col="avg_order_value" label="AOV" sort_by={@sort_by} sort_dir={@sort_dir} />
                <.sort_th
                  col="conversion_rate"
                  label="Conv Rate"
                  sort_by={@sort_by}
                  sort_dir={@sort_dir}
                />
                <%= if @group_by == "campaign" and @has_ad_data do %>
                  <.sort_th col="ad_spend" label="Ad Spend" sort_by={@sort_by} sort_dir={@sort_dir} />
                  <.sort_th col="roas" label="ROAS" sort_by={@sort_by} sort_dir={@sort_dir} />
                  <.sort_th col="cpc" label="CPC" sort_by={@sort_by} sort_dir={@sort_dir} />
                <% else %>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Rev Share
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <tr :if={@rows == []}>
                <td
                  colspan={if(@group_by == "campaign" and @has_ad_data, do: "9", else: "7")}
                  class="px-6 py-8 text-center text-gray-500"
                >
                  No revenue data for this period.
                </td>
              </tr>
              <tr :for={row <- @rows} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm font-medium text-gray-900 max-w-xs">
                  <span class="flex items-center gap-2" title={row["source"] || "Direct"}>
                    <span class="truncate max-w-[250px]">{row["source"] || "Direct"}</span>
                    <span
                      :if={row["ad_platform"] && row["ad_platform"] != ""}
                      class={[
                        "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-semibold shrink-0",
                        ad_pill_class(row["ad_platform"])
                      ]}
                    >
                      {ad_pill_label(row["ad_platform"])}
                    </span>
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(row["visitors"]))}
                </td>
                <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                  {format_number(to_num(row["orders"]))}
                </td>
                <td class="px-6 py-4 text-sm font-medium text-green-600 text-right tabular-nums">
                  {Spectabas.Currency.format(row["total_revenue"], @site.currency)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                  {Spectabas.Currency.format(row["avg_order_value"], @site.currency)}
                </td>
                <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                  {row["conversion_rate"]}%
                </td>
                <%= if @group_by == "campaign" and @has_ad_data do %>
                  <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                    <%= if row["ad_spend"] && row["ad_spend"] > 0 do %>
                      {Spectabas.Currency.format(row["ad_spend"], @site.currency)}
                    <% else %>
                      <span class="text-gray-300">--</span>
                    <% end %>
                  </td>
                  <td class="px-6 py-4 text-sm text-right tabular-nums">
                    <%= if row["roas"] do %>
                      <span class={roas_color(row["roas"])}>{row["roas"]}x</span>
                    <% else %>
                      <span class="text-gray-300">--</span>
                    <% end %>
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                    <%= if row["cpc"] do %>
                      {Spectabas.Currency.format(row["cpc"], @site.currency)}
                    <% else %>
                      <span class="text-gray-300">--</span>
                    <% end %>
                  </td>
                <% else %>
                  <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <div class="w-16 bg-gray-200 rounded-full h-1.5">
                        <div
                          class="bg-indigo-500 h-1.5 rounded-full"
                          style={"width: #{rev_share_pct(row["total_revenue"], @total_revenue)}%"}
                        >
                        </div>
                      </div>
                      <span class="text-xs text-gray-500 tabular-nums w-10 text-right">
                        {rev_share_pct(row["total_revenue"], @total_revenue)}%
                      </span>
                    </div>
                  </td>
                <% end %>
              </tr>
            </tbody>
          </table>
        </div>

        <%!-- Campaign Ad Spend Table (shown when not on Campaign tab but has ad data) --%>
        <div :if={@has_ad_data and @group_by != "campaign"} class="mt-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Ad Spend by Campaign</h2>
          <div class="bg-white rounded-lg shadow overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Campaign
                  </th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                    Platform
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Spend
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Clicks
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    Impressions
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    CPC
                  </th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                    CTR
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <tr :if={@ad_campaigns == []}>
                  <td colspan="7" class="px-6 py-6 text-center text-gray-500">
                    No ad campaign data for this period.
                  </td>
                </tr>
                <tr :for={c <- @ad_campaigns} class="hover:bg-gray-50">
                  <td class="px-6 py-4 text-sm font-medium text-gray-900">
                    {c["campaign_name"] || "(unnamed)"}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-600">
                    <span class="inline-flex items-center gap-1.5">
                      <span class={["w-2 h-2 rounded-full", platform_color(c["platform"])]}></span>
                      {platform_label(c["platform"])}
                    </span>
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {Spectabas.Currency.format(c["total_spend"], @site.currency)}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-900 text-right tabular-nums">
                    {format_number(to_num(c["total_clicks"]))}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                    {format_number(to_num(c["total_impressions"]))}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                    <% clicks = to_num(c["total_clicks"]) %>
                    <% spend = parse_float(c["total_spend"]) %>
                    {if clicks > 0,
                      do: Spectabas.Currency.format(spend / clicks, @site.currency),
                      else: "--"}
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-600 text-right tabular-nums">
                    <% clicks = to_num(c["total_clicks"]) %>
                    <% imps = to_num(c["total_impressions"]) %>
                    {if imps > 0, do: "#{Float.round(clicks / imps * 100, 2)}%", else: "--"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <p class="text-xs text-gray-500 mt-3">
          <strong>{touch_label(@touch)}</strong>
          attribution: {touch_description(@touch)}
          <%= if @has_ad_data do %>
            ROAS = Revenue / Ad Spend.
          <% end %>
        </p>
      </div>
    </.dashboard_layout>
    """
  end

  defp parse_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(n) when is_number(n), do: n / 1
  defp parse_float(_), do: 0.0

  defp rev_share_pct(revenue, total) when total > 0 do
    r = parse_float(revenue)
    Float.round(r / total * 100, 1)
  end

  defp rev_share_pct(_, _), do: 0.0

  defp touch_label("first"), do: "First-touch"
  defp touch_label("last"), do: "Last-touch"
  defp touch_label("any"), do: "Any-touch"

  defp touch_description("first"),
    do: "revenue is credited to the first traffic source the customer came from."

  defp touch_description("last"),
    do: "revenue is credited to the most recent traffic source before purchasing."

  defp touch_description("any"),
    do:
      "revenue is credited to every source the customer touched. Totals may exceed actual revenue since one conversion can appear under multiple sources."

  defp roas_color(roas) when roas >= 3, do: "font-bold text-green-600"
  defp roas_color(roas) when roas >= 1, do: "font-medium text-yellow-600"
  defp roas_color(_), do: "font-medium text-red-600"

  defp sort_th(assigns) do
    assigns = assigns |> Map.put_new(:align, "right")
    active = assigns.col == assigns.sort_by
    arrow = if active, do: if(assigns.sort_dir == "asc", do: " \u2191", else: " \u2193"), else: ""

    assigns = assign(assigns, :active, active)
    assigns = assign(assigns, :arrow, arrow)

    ~H"""
    <th
      phx-click="sort"
      phx-value-col={@col}
      class={"px-6 py-3 text-#{@align} text-xs font-medium uppercase cursor-pointer select-none hover:text-indigo-600 #{if @active, do: "text-indigo-700", else: "text-gray-500"}"}
    >
      {@label}{@arrow}
    </th>
    """
  end

  defp ad_pill_class("google_ads"), do: "bg-blue-100 text-blue-700"
  defp ad_pill_class("bing_ads"), do: "bg-amber-100 text-amber-700"
  defp ad_pill_class("meta_ads"), do: "bg-purple-100 text-purple-700"
  defp ad_pill_class(_), do: "bg-gray-100 text-gray-600"

  defp ad_pill_label("google_ads"), do: "Google Ads"
  defp ad_pill_label("bing_ads"), do: "Bing Ads"
  defp ad_pill_label("meta_ads"), do: "Meta Ads"
  defp ad_pill_label(other), do: other

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label(p), do: p

  defp platform_color("google_ads"), do: "bg-blue-500"
  defp platform_color("bing_ads"), do: "bg-amber-500"
  defp platform_color("meta_ads"), do: "bg-purple-500"
  defp platform_color(_), do: "bg-gray-400"
end
