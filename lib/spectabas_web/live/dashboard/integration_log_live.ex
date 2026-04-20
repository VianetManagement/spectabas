defmodule SpectabasWeb.Dashboard.IntegrationLogLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, AdIntegrations, Repo}
  alias Spectabas.AdIntegrations.SyncLog
  import SpectabasWeb.Dashboard.SidebarComponent
  import Ecto.Query

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      socket =
        socket
        |> assign(:page_title, "Integration Log - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:integrations, [])
        |> assign(:sync_logs, [])
        |> assign(:audit_logs, [])
        |> assign(:user_tz, user.timezone || "America/New_York")
        |> assign(:filter, "all")
        |> assign(:loading, true)

      if connected?(socket), do: send(self(), :load_data)

      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:load_data, socket) do
    site = socket.assigns.site

    all_integrations = AdIntegrations.list_for_site(site.id)
    integrations = Enum.filter(all_integrations, &(&1.status != "revoked"))

    sync_logs =
      try do
        SyncLog.recent_for_site(site.id, 200)
      rescue
        _ -> []
      end

    # Also get audit log entries (connect/disconnect/credentials)
    audit_logs =
      Repo.all(
        from(a in Spectabas.Accounts.AuditLog,
          where:
            fragment("?->>'site_id' = ?", a.metadata, ^to_string(site.id)) and
              a.event in [
                "ad_integration.connected",
                "ad_integration.disconnected",
                "ad_credentials.saved",
                "payment_data.cleared"
              ],
          order_by: [desc: a.occurred_at],
          limit: 50
        )
      )

    {:noreply,
     socket
     |> assign(:integrations, integrations)
     |> assign(:sync_logs, sync_logs)
     |> assign(:audit_logs, audit_logs)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout flash={@flash} site={@site} active="integration_log">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold text-gray-900">Integration Log</h1>
            <p class="text-sm text-gray-500 mt-1">
              Sync history and health for connected integrations
            </p>
          </div>
          <.link
            navigate={~p"/dashboard/sites/#{@site.id}/settings"}
            class="text-sm text-indigo-600 hover:text-indigo-800 font-medium"
          >
            Manage Integrations &rarr;
          </.link>
        </div>

        <%!-- Integration cards --%>
        <%= if @integrations == [] do %>
          <div class="bg-white rounded-lg shadow p-8 text-center">
            <p class="text-gray-500">
              No integrations connected.
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/settings"}
                class="text-indigo-600 underline"
              >
                Add one in Settings
              </.link>
            </p>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4 mb-8">
            <%= for integration <- @integrations do %>
              <div class={"bg-white rounded-lg shadow p-5 border-l-4 " <> health_border(integration)}>
                <div class="flex items-center justify-between mb-2">
                  <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full " <> platform_color(integration.platform)}>
                    {platform_label(integration.platform)}
                  </span>
                  <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full " <> status_badge(integration.status)}>
                    {integration.status}
                  </span>
                </div>

                <div class="text-sm text-gray-600 space-y-1">
                  <div :if={integration.account_name && integration.account_name != ""}>
                    <span class="text-gray-500">Account:</span>
                    <span class="font-medium">{integration.account_name}</span>
                  </div>
                  <div>
                    <span class="text-gray-500">Last sync:</span>
                    <%= if integration.last_synced_at do %>
                      <span class="font-medium">
                        {format_ts(integration.last_synced_at, @user_tz)}
                      </span>
                      <span class="text-gray-400 text-xs">
                        ({time_ago(integration.last_synced_at)})
                      </span>
                    <% else %>
                      <span class="text-amber-500 font-medium">Never</span>
                    <% end %>
                  </div>
                  <div>
                    <span class="text-gray-500">Frequency:</span>
                    <span class="font-medium">
                      {format_frequency(AdIntegrations.sync_frequency(integration))}
                    </span>
                  </div>
                  <%= if integration.last_error do %>
                    <div class="mt-2 p-2 bg-red-50 rounded text-xs text-red-700">
                      {String.slice(integration.last_error, 0, 120)}
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Filter tabs --%>
          <div class="flex gap-2 mb-4">
            <button
              :for={
                {val, label} <- [
                  {"all", "All Events"},
                  {"sync", "Syncs Only"},
                  {"errors", "Errors Only"},
                  {"config", "Config Changes"}
                ]
              }
              phx-click="filter"
              phx-value-filter={val}
              class={"px-3 py-1.5 text-sm rounded-full font-medium " <> if(@filter == val, do: "bg-indigo-100 text-indigo-700", else: "bg-gray-100 text-gray-600 hover:bg-gray-200")}
            >
              {label}
              <%= if val == "errors" do %>
                <% error_count = Enum.count(@sync_logs, &(&1.status == "error")) %>
                <span
                  :if={error_count > 0}
                  class="ml-1 px-1.5 py-0.5 text-xs rounded-full bg-red-100 text-red-600"
                >
                  {error_count}
                </span>
              <% end %>
            </button>
          </div>

          <%!-- Sync event log --%>
          <div class="bg-white rounded-lg shadow">
            <div class="px-6 py-4 border-b border-gray-200">
              <h2 class="text-lg font-semibold text-gray-900">Sync Events</h2>
              <p class="text-xs text-gray-500 mt-0.5">Detailed log of all sync operations</p>
            </div>

            <% filtered_logs = filter_logs(@sync_logs, @audit_logs, @filter) %>

            <%= if filtered_logs == [] do %>
              <div class="p-8 text-center text-gray-500 text-sm">
                No events recorded yet. Events will appear after the first sync runs.
              </div>
            <% else %>
              <div class="divide-y divide-gray-100 max-h-[600px] overflow-y-auto">
                <%= for entry <- filtered_logs do %>
                  <div class="px-6 py-3 hover:bg-gray-50">
                    <div class="flex items-start gap-3">
                      <div class={"w-2 h-2 mt-2 rounded-full shrink-0 " <> entry_dot(entry)}></div>
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2">
                          <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded " <> platform_color(entry.platform)}>
                            {platform_label(entry.platform)}
                          </span>
                          <span class={"text-xs font-medium px-1.5 py-0.5 rounded " <> event_badge(entry.event)}>
                            {entry.event_label}
                          </span>
                          <span :if={entry.duration_ms} class="text-xs text-gray-400">
                            {format_duration(entry.duration_ms)}
                          </span>
                        </div>
                        <div class="text-sm text-gray-700 mt-1">{entry.message}</div>
                        <%= if entry.details != %{} and entry.details != nil do %>
                          <div class="text-xs text-gray-400 mt-0.5 font-mono">
                            {format_details(entry.details)}
                          </div>
                        <% end %>
                      </div>
                      <div class="text-xs text-gray-400 shrink-0 whitespace-nowrap">
                        {format_naive_ts(entry.timestamp, @user_tz)}
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp filter_logs(sync_logs, audit_logs, filter) do
    sync_entries =
      Enum.map(sync_logs, fn log ->
        %{
          platform: log.platform,
          event: log.event,
          event_label: sync_event_label(log.event),
          status: log.status,
          message: log.message || "",
          details: log.details || %{},
          duration_ms: log.duration_ms,
          timestamp: log.inserted_at
        }
      end)

    audit_entries =
      Enum.map(audit_logs, fn log ->
        %{
          platform: (log.metadata || %{})["platform"] || "unknown",
          event: log.event,
          event_label: audit_event_label(log.event),
          status: "info",
          message: format_audit_metadata(log.metadata),
          details: %{},
          duration_ms: nil,
          timestamp: log.occurred_at
        }
      end)

    all =
      case filter do
        "sync" -> sync_entries |> Enum.filter(&(&1.event not in ["manual_sync_start"]))
        "errors" -> sync_entries |> Enum.filter(&(&1.status == "error"))
        "config" -> audit_entries
        _ -> sync_entries ++ audit_entries
      end

    Enum.sort_by(all, & &1.timestamp, {:desc, NaiveDateTime})
  end

  defp sync_event_label("cron_sync"), do: "Scheduled Sync"
  defp sync_event_label("manual_sync"), do: "Manual Sync"
  defp sync_event_label("manual_sync_start"), do: "Sync Started"
  defp sync_event_label("ad_sync"), do: "Ad Spend Sync"
  defp sync_event_label("day_sync"), do: "Day Sync"
  defp sync_event_label("token_refresh"), do: "Token Refresh"
  defp sync_event_label(e), do: e

  defp audit_event_label("ad_integration.connected"), do: "Connected"
  defp audit_event_label("ad_integration.disconnected"), do: "Disconnected"
  defp audit_event_label("ad_credentials.saved"), do: "Credentials Updated"
  defp audit_event_label("payment_data.cleared"), do: "Data Cleared"
  defp audit_event_label(e), do: e

  defp entry_dot(%{status: "error"}), do: "bg-red-500"
  defp entry_dot(%{status: "info"}), do: "bg-blue-500"
  defp entry_dot(%{event: "manual_sync_start"}), do: "bg-amber-500"
  defp entry_dot(%{event: "ad_integration.connected"}), do: "bg-green-500"
  defp entry_dot(%{event: "ad_integration.disconnected"}), do: "bg-red-500"
  defp entry_dot(_), do: "bg-green-500"

  defp event_badge("cron_sync"), do: "bg-gray-100 text-gray-600"
  defp event_badge("manual_sync"), do: "bg-indigo-100 text-indigo-600"
  defp event_badge("manual_sync_start"), do: "bg-amber-100 text-amber-600"
  defp event_badge("ad_sync"), do: "bg-blue-100 text-blue-600"
  defp event_badge("token_refresh"), do: "bg-yellow-100 text-yellow-700"
  defp event_badge("day_sync"), do: "bg-gray-100 text-gray-600"
  defp event_badge("ad_integration.connected"), do: "bg-green-100 text-green-600"
  defp event_badge("ad_integration.disconnected"), do: "bg-red-100 text-red-600"
  defp event_badge("ad_credentials.saved"), do: "bg-blue-100 text-blue-600"
  defp event_badge("payment_data.cleared"), do: "bg-amber-100 text-amber-600"
  defp event_badge(_), do: "bg-gray-100 text-gray-600"

  defp format_details(details) when is_map(details) do
    details
    |> Enum.reject(fn {_k, v} -> v == nil or v == "" end)
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(" · ")
  end

  defp format_details(_), do: ""

  defp format_duration(nil), do: ""
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"

  defp format_audit_metadata(nil), do: ""

  defp format_audit_metadata(meta) when is_map(meta) do
    parts =
      [
        if(meta["platform"], do: "Platform: #{meta["platform"]}"),
        if(meta["account_id"] && meta["account_id"] != "", do: "Account: #{meta["account_id"]}")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " · ")
  end

  defp health_border(integration) do
    cond do
      integration.last_error != nil ->
        "border-red-400"

      integration.last_synced_at == nil ->
        "border-amber-400"

      time_since_sync(integration) > AdIntegrations.sync_frequency(integration) * 2 ->
        "border-amber-400"

      true ->
        "border-green-400"
    end
  end

  defp time_since_sync(%{last_synced_at: nil}), do: 999_999

  defp time_since_sync(%{last_synced_at: ts}) do
    DateTime.diff(DateTime.utc_now(), ts, :minute)
  end

  defp time_ago(dt) do
    minutes = DateTime.diff(DateTime.utc_now(), dt, :minute)

    cond do
      minutes < 1 -> "just now"
      minutes < 60 -> "#{minutes}m ago"
      minutes < 1440 -> "#{div(minutes, 60)}h ago"
      true -> "#{div(minutes, 1440)}d ago"
    end
  end

  defp format_frequency(minutes) do
    cond do
      minutes < 60 -> "#{minutes} min"
      minutes == 60 -> "1 hour"
      minutes < 1440 -> "#{div(minutes, 60)} hours"
      true -> "#{div(minutes, 1440)} days"
    end
  end

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label("pinterest_ads"), do: "Pinterest"
  defp platform_label("reddit_ads"), do: "Reddit"
  defp platform_label("tiktok_ads"), do: "TikTok"
  defp platform_label("twitter_ads"), do: "X / Twitter"
  defp platform_label("linkedin_ads"), do: "LinkedIn"
  defp platform_label("snapchat_ads"), do: "Snapchat"
  defp platform_label("stripe"), do: "Stripe"
  defp platform_label("braintree"), do: "Braintree"
  defp platform_label("google_search_console"), do: "Search Console"
  defp platform_label("bing_webmaster"), do: "Bing Webmaster"
  defp platform_label(p), do: p

  defp platform_color("google_ads"), do: "bg-blue-100 text-blue-700"
  defp platform_color("bing_ads"), do: "bg-amber-100 text-amber-700"
  defp platform_color("meta_ads"), do: "bg-purple-100 text-purple-700"
  defp platform_color("pinterest_ads"), do: "bg-red-100 text-red-700"
  defp platform_color("reddit_ads"), do: "bg-orange-100 text-orange-700"
  defp platform_color("tiktok_ads"), do: "bg-gray-200 text-gray-900"
  defp platform_color("twitter_ads"), do: "bg-sky-100 text-sky-700"
  defp platform_color("linkedin_ads"), do: "bg-blue-100 text-blue-800"
  defp platform_color("snapchat_ads"), do: "bg-yellow-100 text-yellow-700"
  defp platform_color("stripe"), do: "bg-indigo-100 text-indigo-700"
  defp platform_color("braintree"), do: "bg-teal-100 text-teal-700"
  defp platform_color("google_search_console"), do: "bg-green-100 text-green-700"
  defp platform_color("bing_webmaster"), do: "bg-cyan-100 text-cyan-700"
  defp platform_color(_), do: "bg-gray-100 text-gray-600"

  defp status_badge("active"), do: "bg-green-100 text-green-700"
  defp status_badge("revoked"), do: "bg-red-100 text-red-700"
  defp status_badge(_), do: "bg-gray-100 text-gray-600"

  defp format_ts(nil, _tz), do: "Never"

  defp format_ts(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M %Z")
      _ -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end

  defp format_ts(dt, _tz), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp format_naive_ts(nil, _tz), do: ""

  defp format_naive_ts(%NaiveDateTime{} = ndt, tz) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, utc} ->
        case DateTime.shift_zone(utc, tz) do
          {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M:%S %Z")
          _ -> Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S UTC")
        end

      _ ->
        Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S UTC")
    end
  end

  defp format_naive_ts(dt, _tz), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
end
