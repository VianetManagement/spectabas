defmodule SpectabasWeb.Dashboard.IntegrationLogLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, AdIntegrations, Repo}
  import SpectabasWeb.Dashboard.SidebarComponent
  import Ecto.Query

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      all_integrations = AdIntegrations.list_for_site(site.id)
      integrations = Enum.filter(all_integrations, &(&1.status != "revoked"))

      # Get audit log entries for this site's integrations
      integration_ids = Enum.map(integrations, & &1.id)

      logs =
        if integration_ids != [] do
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
        else
          []
        end

      {:ok,
       socket
       |> assign(:page_title, "Integration Log - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:integrations, integrations)
       |> assign(:logs, logs)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout flash={@flash} site={@site}>
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
                        {Calendar.strftime(integration.last_synced_at, "%Y-%m-%d %H:%M")} UTC
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

          <%!-- Activity log --%>
          <div class="bg-white rounded-lg shadow p-6">
            <h2 class="text-lg font-semibold text-gray-900 mb-4">Recent Activity</h2>
            <%= if @logs == [] do %>
              <p class="text-sm text-gray-500">No integration activity recorded yet.</p>
            <% else %>
              <div class="space-y-3">
                <%= for log <- @logs do %>
                  <div class="flex items-start gap-3 py-2 border-b border-gray-100 last:border-0">
                    <div class={"w-2 h-2 mt-1.5 rounded-full shrink-0 " <> event_dot(log.event)}>
                    </div>
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium text-gray-900">{event_label(log.event)}</div>
                      <div class="text-xs text-gray-500 mt-0.5">
                        {format_metadata(log.metadata)}
                      </div>
                    </div>
                    <div class="text-xs text-gray-400 shrink-0">
                      {Calendar.strftime(log.occurred_at, "%Y-%m-%d %H:%M")}
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

  defp health_border(integration) do
    cond do
      integration.last_error != nil ->
        "border-red-400"

      integration.last_synced_at == nil ->
        "border-amber-400"

      time_since_sync(integration) > integration_expected_interval(integration) * 2 ->
        "border-amber-400"

      true ->
        "border-green-400"
    end
  end

  defp time_since_sync(%{last_synced_at: nil}), do: 999_999

  defp time_since_sync(%{last_synced_at: ts}) do
    DateTime.diff(DateTime.utc_now(), ts, :minute)
  end

  defp integration_expected_interval(integration) do
    AdIntegrations.sync_frequency(integration)
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
  defp platform_label("stripe"), do: "Stripe"
  defp platform_label("braintree"), do: "Braintree"
  defp platform_label("google_search_console"), do: "Search Console"
  defp platform_label("bing_webmaster"), do: "Bing Webmaster"
  defp platform_label(p), do: p

  defp platform_color("google_ads"), do: "bg-blue-100 text-blue-700"
  defp platform_color("bing_ads"), do: "bg-amber-100 text-amber-700"
  defp platform_color("meta_ads"), do: "bg-purple-100 text-purple-700"
  defp platform_color("stripe"), do: "bg-indigo-100 text-indigo-700"
  defp platform_color("braintree"), do: "bg-teal-100 text-teal-700"
  defp platform_color("google_search_console"), do: "bg-green-100 text-green-700"
  defp platform_color("bing_webmaster"), do: "bg-cyan-100 text-cyan-700"
  defp platform_color(_), do: "bg-gray-100 text-gray-600"

  defp status_badge("active"), do: "bg-green-100 text-green-700"
  defp status_badge("revoked"), do: "bg-red-100 text-red-700"
  defp status_badge(_), do: "bg-gray-100 text-gray-600"

  defp event_dot("ad_integration.connected"), do: "bg-green-500"
  defp event_dot("ad_integration.disconnected"), do: "bg-red-500"
  defp event_dot("ad_credentials.saved"), do: "bg-blue-500"
  defp event_dot("payment_data.cleared"), do: "bg-amber-500"
  defp event_dot(_), do: "bg-gray-400"

  defp event_label("ad_integration.connected"), do: "Integration connected"
  defp event_label("ad_integration.disconnected"), do: "Integration disconnected"
  defp event_label("ad_credentials.saved"), do: "Credentials updated"
  defp event_label("payment_data.cleared"), do: "Data cleared"
  defp event_label(e), do: e

  defp format_metadata(nil), do: ""

  defp format_metadata(meta) when is_map(meta) do
    parts =
      [
        if(meta["platform"], do: "Platform: #{meta["platform"]}"),
        if(meta["account_id"] && meta["account_id"] != "", do: "Account: #{meta["account_id"]}")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " · ")
  end
end
