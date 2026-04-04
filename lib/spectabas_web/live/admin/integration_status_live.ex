defmodule SpectabasWeb.Admin.IntegrationStatusLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{AdIntegrations, Repo}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    sites =
      if user.role == :platform_admin do
        Spectabas.Sites.list_sites()
      else
        Spectabas.Accounts.accessible_sites(user)
      end

    integrations =
      Enum.flat_map(sites, fn site ->
        AdIntegrations.list_for_site(site.id)
        |> Repo.preload(:site)
      end)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:ok,
     socket
     |> assign(:page_title, "Integration Status")
     |> assign(:integrations, integrations)
     |> assign(:test_results, %{})}
  end

  @impl true
  def handle_event("test_integration", %{"id" => id}, socket) do
    integration = AdIntegrations.get!(id) |> Repo.preload(:site)

    result = test_integration(integration)

    test_results = Map.put(socket.assigns.test_results, integration.id, result)

    {:noreply, assign(socket, :test_results, test_results)}
  end

  defp test_integration(%{platform: "stripe"} = integration) do
    api_key = AdIntegrations.decrypt_access_token(integration)

    case Req.get("https://api.stripe.com/v1/charges?limit=1",
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"stripe-version", "2024-12-18.acacia"}
           ]
         ) do
      {:ok, %{status: 200}} ->
        %{status: :ok, message: "API key valid, connected"}

      {:ok, %{status: s, body: b}} ->
        msg = if is_map(b), do: get_in(b, ["error", "message"]) || "HTTP #{s}", else: "HTTP #{s}"
        %{status: :error, message: msg}

      {:error, reason} ->
        %{status: :error, message: "Connection failed: #{inspect(reason)}"}
    end
  end

  defp test_integration(%{platform: "google_search_console"} = integration) do
    access_token = AdIntegrations.decrypt_access_token(integration)
    site_url = (integration.extra || %{})["site_url"] || ""

    cond do
      site_url == "" ->
        %{status: :error, message: "No site_url in integration extra field"}

      AdIntegrations.token_expired?(integration) ->
        %{
          status: :warning,
          message: "Token expired — needs refresh (happens automatically on next sync)"
        }

      true ->
        encoded = URI.encode(site_url, &URI.char_unreserved?/1)

        case Req.get(
               "https://www.googleapis.com/webmasters/v3/sites/#{encoded}/searchAnalytics/query",
               body:
                 Jason.encode!(%{
                   startDate: Date.to_iso8601(Date.add(Date.utc_today(), -5)),
                   endDate: Date.to_iso8601(Date.add(Date.utc_today(), -3)),
                   dimensions: ["query"],
                   rowLimit: 1
                 }),
               headers: [
                 {"authorization", "Bearer #{access_token}"},
                 {"content-type", "application/json"}
               ],
               method: :post
             ) do
          {:ok, %{status: 200, body: %{"rows" => rows}}} ->
            %{status: :ok, message: "Connected, #{length(rows)} row(s) returned for test query"}

          {:ok, %{status: 200}} ->
            %{
              status: :ok,
              message: "Connected, no data for test date range (normal if site is new)"
            }

          {:ok, %{status: 401}} ->
            %{status: :error, message: "Token invalid or expired — disconnect and reconnect"}

          {:ok, %{status: 403, body: b}} ->
            msg =
              if is_map(b), do: get_in(b, ["error", "message"]) || "Forbidden", else: "Forbidden"

            %{status: :error, message: "Access denied: #{msg}"}

          {:ok, %{status: s, body: b}} ->
            msg =
              if is_map(b), do: get_in(b, ["error", "message"]) || "HTTP #{s}", else: "HTTP #{s}"

            %{status: :error, message: msg}

          {:error, reason} ->
            %{status: :error, message: "Connection failed: #{inspect(reason)}"}
        end
    end
  end

  defp test_integration(%{platform: platform} = integration)
       when platform in ["google_ads", "bing_ads", "meta_ads"] do
    if AdIntegrations.token_expired?(integration) do
      %{status: :warning, message: "Token expired — will refresh on next sync"}
    else
      %{status: :ok, message: "Token active, expires #{integration.token_expires_at || "never"}"}
    end
  end

  defp test_integration(%{platform: "braintree"}) do
    %{status: :ok, message: "Credentials stored (Braintree API test not implemented)"}
  end

  defp test_integration(%{platform: "bing_webmaster"}) do
    %{status: :ok, message: "API key stored (Bing test not implemented)"}
  end

  defp test_integration(_) do
    %{status: :ok, message: "Unknown platform"}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <h1 class="text-2xl font-bold text-gray-900 mb-2">Integration Status</h1>
      <p class="text-sm text-gray-500 mb-6">
        Health and sync status for all connected third-party integrations
      </p>

      <%= if @integrations == [] do %>
        <div class="bg-white rounded-lg shadow p-8 text-center">
          <p class="text-gray-500">No integrations connected yet.</p>
        </div>
      <% else %>
        <div class="bg-white rounded-lg shadow overflow-hidden">
          <table class="w-full">
            <thead class="bg-gray-50">
              <tr>
                <th class="text-left px-4 py-3 text-sm font-semibold text-gray-700">Site</th>
                <th class="text-left px-4 py-3 text-sm font-semibold text-gray-700">Platform</th>
                <th class="text-center px-4 py-3 text-sm font-semibold text-gray-700">Status</th>
                <th class="text-left px-4 py-3 text-sm font-semibold text-gray-700">Account</th>
                <th class="text-right px-4 py-3 text-sm font-semibold text-gray-700">Last Sync</th>
                <th class="text-left px-4 py-3 text-sm font-semibold text-gray-700">Last Error</th>
                <th class="text-right px-4 py-3 text-sm font-semibold text-gray-700">Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for integration <- @integrations do %>
                <tr class="border-t border-gray-100 hover:bg-gray-50">
                  <td class="px-4 py-3 text-sm font-medium text-gray-900">
                    {(integration.site && integration.site.name) || "—"}
                  </td>
                  <td class="px-4 py-3">
                    <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full " <> platform_color(integration.platform)}>
                      {platform_label(integration.platform)}
                    </span>
                  </td>
                  <td class="text-center px-4 py-3">
                    <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full " <> status_color(integration.status)}>
                      {integration.status}
                    </span>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-600 max-w-xs truncate">
                    {integration.account_name || integration.account_id || "—"}
                  </td>
                  <td class="text-right px-4 py-3 text-sm text-gray-500">
                    <%= if integration.last_synced_at do %>
                      {Calendar.strftime(integration.last_synced_at, "%Y-%m-%d %H:%M")} UTC
                    <% else %>
                      <span class="text-amber-500">Never</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-sm max-w-xs truncate">
                    <%= if integration.last_error do %>
                      <span class="text-red-600" title={integration.last_error}>
                        {String.slice(integration.last_error, 0, 60)}
                      </span>
                    <% else %>
                      <span class="text-green-600">None</span>
                    <% end %>
                  </td>
                  <td class="text-right px-4 py-3">
                    <button
                      phx-click="test_integration"
                      phx-value-id={integration.id}
                      class="inline-flex items-center px-2 py-1 text-xs font-medium rounded text-indigo-700 bg-indigo-50 hover:bg-indigo-100 border border-indigo-200"
                    >
                      Test
                    </button>
                  </td>
                </tr>
                <%= if test_result = @test_results[integration.id] do %>
                  <tr class={"border-t " <> test_bg(test_result.status)}>
                    <td colspan="7" class="px-4 py-2 text-sm">
                      <span class={"font-medium " <> test_text(test_result.status)}>
                        {test_status_label(test_result.status)}:
                      </span>
                      {test_result.message}
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label("stripe"), do: "Stripe"
  defp platform_label("braintree"), do: "Braintree"
  defp platform_label("google_search_console"), do: "GSC"
  defp platform_label("bing_webmaster"), do: "Bing WMT"
  defp platform_label(p), do: p

  defp platform_color("google_ads"), do: "bg-blue-100 text-blue-700"
  defp platform_color("bing_ads"), do: "bg-amber-100 text-amber-700"
  defp platform_color("meta_ads"), do: "bg-purple-100 text-purple-700"
  defp platform_color("stripe"), do: "bg-indigo-100 text-indigo-700"
  defp platform_color("braintree"), do: "bg-teal-100 text-teal-700"
  defp platform_color("google_search_console"), do: "bg-green-100 text-green-700"
  defp platform_color("bing_webmaster"), do: "bg-cyan-100 text-cyan-700"
  defp platform_color(_), do: "bg-gray-100 text-gray-600"

  defp status_color("active"), do: "bg-green-100 text-green-700"
  defp status_color("revoked"), do: "bg-red-100 text-red-700"
  defp status_color("error"), do: "bg-red-100 text-red-700"
  defp status_color(_), do: "bg-gray-100 text-gray-600"

  defp test_bg(:ok), do: "bg-green-50"
  defp test_bg(:warning), do: "bg-amber-50"
  defp test_bg(:error), do: "bg-red-50"

  defp test_text(:ok), do: "text-green-700"
  defp test_text(:warning), do: "text-amber-700"
  defp test_text(:error), do: "text-red-700"

  defp test_status_label(:ok), do: "OK"
  defp test_status_label(:warning), do: "Warning"
  defp test_status_label(:error), do: "Error"
end
