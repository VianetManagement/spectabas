defmodule SpectabasWeb.Admin.IntegrationStatusLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{AdIntegrations, Repo}

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
      |> Enum.reject(&(&1.status == "revoked"))
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    {:ok,
     socket
     |> assign(:page_title, "Integration Status")
     |> assign(:integrations, integrations)
     |> assign(:user_tz, user.timezone || "America/New_York")
     |> assign(:test_results, %{})}
  end

  @impl true
  def handle_event("test_integration", %{"id" => id}, socket) do
    integration = AdIntegrations.get!(id) |> Repo.preload(:site)

    result = test_integration(integration)

    test_results = Map.put(socket.assigns.test_results, integration.id, result)

    {:noreply, assign(socket, :test_results, test_results)}
  end

  def handle_event("sync_test", %{"id" => id}, socket) do
    integration = AdIntegrations.get!(id) |> Repo.preload(:site)

    result =
      try do
        case integration.platform do
          "google_search_console" ->
            date = Date.add(Date.utc_today(), -3)
            site_url = (integration.extra || %{})["site_url"] || ""

            # Refresh token if expired
            {integration, token_status} =
              if AdIntegrations.token_expired?(integration) do
                rt = AdIntegrations.decrypt_refresh_token(integration)

                _creds =
                  Spectabas.AdIntegrations.Credentials.get_for_platform(
                    integration.site,
                    "google_search_console"
                  )

                case Spectabas.AdIntegrations.Platforms.GoogleSearchConsole.refresh_token(
                       integration.site,
                       rt
                     ) do
                  {:ok, %{access_token: at, expires_in: ei}} ->
                    expires_at =
                      DateTime.utc_now()
                      |> DateTime.add(ei || 3600, :second)
                      |> DateTime.truncate(:second)

                    {:ok, updated} = AdIntegrations.update_tokens(integration, at, rt, expires_at)
                    {updated, "refreshed (was expired)"}

                  {:error, reason} ->
                    {integration, "REFRESH FAILED: #{inspect(reason)}"}
                end
              else
                {integration, "valid"}
              end

            # Try fetch
            fetch_result =
              Spectabas.AdIntegrations.Platforms.GoogleSearchConsole.fetch_search_data(
                integration,
                site_url,
                date
              )

            # Try insert if fetch worked
            insert_result =
              case fetch_result do
                {:ok, rows} when rows != [] ->
                  Spectabas.AdIntegrations.Platforms.GoogleSearchConsole.sync_search_data(
                    integration.site,
                    integration,
                    date
                  )

                {:ok, []} ->
                  "no_data_for_#{date}"

                {:error, reason} ->
                  "fetch_error: #{inspect(reason)}"
              end

            %{
              status: :ok,
              message:
                "token=#{token_status}, site_url=#{site_url}, date=#{date}, " <>
                  "fetch=#{inspect(elem(fetch_result, 0))}(#{if match?({:ok, rows} when is_list(rows), fetch_result), do: length(elem(fetch_result, 1)), else: "err"} rows), " <>
                  "insert=#{inspect(insert_result)}"
            }

          "stripe" ->
            # MRR diagnostic — compare our calculation vs raw Stripe data
            api_key = AdIntegrations.decrypt_access_token(integration)

            case Req.get(
                   "https://api.stripe.com/v1/subscriptions?status=active&limit=10&expand[]=data.discount.coupon",
                   headers: [
                     {"authorization", "Bearer #{api_key}"},
                     {"stripe-version", "2024-12-18.acacia"}
                   ]
                 ) do
              {:ok, %{status: 200, body: %{"data" => subs}}} ->
                samples =
                  Enum.map(subs, fn sub ->
                    items = get_in(sub, ["items", "data"]) || []

                    stripe_amount =
                      Enum.reduce(items, 0, fn i, acc ->
                        acc + (i["quantity"] || 1) * (get_in(i, ["price", "unit_amount"]) || 0)
                      end) / 100.0

                    interval =
                      get_in(items, [Access.at(0), "price", "recurring", "interval"]) || "month"

                    interval_count =
                      get_in(items, [Access.at(0), "price", "recurring", "interval_count"]) || 1

                    discount_pct = get_in(sub, ["discount", "coupon", "percent_off"]) || 0
                    amount_off = (get_in(sub, ["discount", "coupon", "amount_off"]) || 0) / 100.0

                    discounted =
                      cond do
                        discount_pct > 0 -> stripe_amount * (1 - discount_pct / 100.0)
                        amount_off > 0 -> max(stripe_amount - amount_off, 0)
                        true -> stripe_amount
                      end

                    our_mrr =
                      case interval do
                        "year" -> discounted / (12.0 * interval_count)
                        "month" -> discounted / interval_count
                        _ -> discounted
                      end

                    %{
                      id: String.slice(sub["id"], 0, 20),
                      status: sub["status"],
                      amount: stripe_amount,
                      discount: "#{discount_pct}% / $#{amount_off}",
                      interval: "#{interval}/#{interval_count}",
                      our_mrr: Float.round(our_mrr, 2)
                    }
                  end)

                total_our_mrr = samples |> Enum.map(& &1.our_mrr) |> Enum.sum() |> Float.round(2)

                %{
                  status: :ok,
                  message:
                    "#{length(subs)} active subs sampled. Our MRR for sample: $#{total_our_mrr}. Details: #{inspect(samples, limit: :infinity)}"
                }

              {:ok, %{status: s, body: b}} ->
                %{
                  status: :error,
                  message: "Stripe API #{s}: #{inspect(b) |> String.slice(0, 200)}"
                }

              {:error, reason} ->
                %{status: :error, message: inspect(reason)}
            end

          _ ->
            %{status: :ok, message: "Sync test not implemented for #{integration.platform}"}
        end
      rescue
        e ->
          %{status: :error, message: "Crash: #{Exception.message(e)}"}
      end

    test_results = Map.put(socket.assigns.test_results, integration.id, result)
    {:noreply, assign(socket, :test_results, test_results)}
  end

  def handle_event("clear_error", %{"id" => id}, socket) do
    integration = AdIntegrations.get!(id)

    integration
    |> Spectabas.AdIntegrations.AdIntegration.changeset(%{last_error: nil})
    |> Repo.update()

    {:noreply,
     socket
     |> put_flash(:info, "Error cleared.")
     |> assign(:integrations, reload_integrations(socket))}
  end

  def handle_event("backfill_search", %{"id" => id}, socket) do
    integration = AdIntegrations.get!(id) |> Repo.preload(:site)

    Task.start(fn ->
      try do
        if integration.platform == "bing_webmaster" do
          # Bing: single API call returns all data — use bulk sync
          alias Spectabas.AdIntegrations.SyncLog

          SyncLog.log(integration, "manual_sync_start", "ok", "Bing bulk sync started")
          start = System.monotonic_time(:millisecond)

          case Spectabas.AdIntegrations.Platforms.BingWebmaster.sync_all_data(
                 integration.site,
                 integration
               ) do
            {:ok, count} ->
              ms = System.monotonic_time(:millisecond) - start
              status = if count == 0, do: "error", else: "ok"

              SyncLog.log(
                integration,
                "manual_sync",
                status,
                "Bing bulk sync: #{count} rows inserted. Check Render logs for [Bing] debug output.",
                duration_ms: ms
              )

            {:error, reason} ->
              ms = System.monotonic_time(:millisecond) - start

              SyncLog.log(
                integration,
                "manual_sync",
                "error",
                "Bing bulk sync failed: #{inspect(reason)}",
                duration_ms: ms
              )
          end
        else
          Spectabas.Workers.SearchConsoleSync.sync_now(integration, force_backfill: true)
        end
      rescue
        e ->
          require Logger
          Logger.error("[SearchConsole:backfill] Crash: #{Exception.message(e)}")
      end
    end)

    {:noreply,
     put_flash(
       socket,
       :info,
       "Backfill started. Check Integration Log for progress."
     )}
  end

  def handle_event("fix_gsc_url", %{"id" => id}, socket) do
    integration = AdIntegrations.get!(id) |> Repo.preload(:site)
    site_url = (integration.extra || %{})["site_url"] || ""

    # Fix URL based on platform
    fixed_url =
      case integration.platform do
        "google_search_console" ->
          cond do
            String.starts_with?(site_url, "sc-domain:") ->
              site_url

            String.starts_with?(site_url, "http") ->
              site_url

            site_url != "" ->
              "sc-domain:#{site_url}"

            true ->
              # Derive from site domain
              parent = Spectabas.Sites.parent_domain_for(integration.site)
              "sc-domain:#{parent}"
          end

        "bing_webmaster" ->
          if site_url == "" do
            # Bing registers sites as bare domain (e.g., "roommates.com")
            Spectabas.Sites.parent_domain_for(integration.site)
          else
            site_url
          end

        _ ->
          site_url
      end

    if fixed_url != site_url do
      extra = Map.put(integration.extra || %{}, "site_url", fixed_url)

      integration
      |> Spectabas.AdIntegrations.AdIntegration.changeset(%{
        extra: extra,
        account_id: fixed_url,
        account_name: fixed_url
      })
      |> Repo.update()

      {:noreply,
       socket
       |> put_flash(:info, "Fixed GSC site_url: #{site_url} → #{fixed_url}")
       |> assign(:integrations, reload_integrations(socket))}
    else
      {:noreply, put_flash(socket, :info, "site_url already correct: #{site_url}")}
    end
  end

  defp reload_integrations(socket) do
    user = socket.assigns.current_scope.user

    sites =
      if user.role == :platform_admin do
        Spectabas.Sites.list_sites()
      else
        Spectabas.Accounts.accessible_sites(user)
      end

    Enum.flat_map(sites, fn site ->
      AdIntegrations.list_for_site(site.id)
      |> Repo.preload(:site)
    end)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp test_integration(%{platform: "stripe"} = integration) do
    api_key = AdIntegrations.decrypt_access_token(integration)

    # Fetch 10 active subs and show MRR calculation per sub
    case Req.get(
           "https://api.stripe.com/v1/subscriptions?status=active&limit=10&expand[]=data.discount.coupon",
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"stripe-version", "2024-12-18.acacia"}
           ]
         ) do
      {:ok, %{status: 200, body: %{"data" => subs}}} ->
        samples =
          Enum.map(subs, fn sub ->
            items = get_in(sub, ["items", "data"]) || []

            stripe_amount =
              Enum.reduce(items, 0, fn i, acc ->
                acc + (i["quantity"] || 1) * (get_in(i, ["price", "unit_amount"]) || 0)
              end) / 100.0

            interval = get_in(items, [Access.at(0), "price", "recurring", "interval"]) || "month"

            interval_count =
              get_in(items, [Access.at(0), "price", "recurring", "interval_count"]) || 1

            discount_pct = get_in(sub, ["discount", "coupon", "percent_off"]) || 0
            amount_off = (get_in(sub, ["discount", "coupon", "amount_off"]) || 0) / 100.0

            discounted =
              cond do
                discount_pct > 0 -> stripe_amount * (1 - discount_pct / 100.0)
                amount_off > 0 -> max(stripe_amount - amount_off, 0)
                true -> stripe_amount
              end

            our_mrr =
              case interval do
                "year" -> discounted / (12.0 * interval_count)
                "month" -> discounted / interval_count
                _ -> discounted
              end

            "$#{Float.round(our_mrr, 2)} (#{interval}/#{interval_count}, amt=$#{stripe_amount}, disc=#{discount_pct}%/$#{amount_off})"
          end)

        total = subs |> length()
        sample_mrr = samples |> Enum.join(", ")

        %{status: :ok, message: "API valid. #{total} active subs sampled: #{sample_mrr}"}

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

        body =
          Jason.encode!(%{
            startDate: Date.to_iso8601(Date.add(Date.utc_today(), -5)),
            endDate: Date.to_iso8601(Date.add(Date.utc_today(), -3)),
            dimensions: ["query"],
            rowLimit: 1
          })

        case Req.post(
               "https://www.googleapis.com/webmasters/v3/sites/#{encoded}/searchAnalytics/query",
               body: body,
               headers: [
                 {"authorization", "Bearer #{access_token}"},
                 {"content-type", "application/json"}
               ]
             ) do
          {:ok, %{status: 200, body: %{"rows" => rows}}} ->
            %{
              status: :ok,
              message: "Connected, #{length(rows)} row(s) for test query. site_url=#{site_url}"
            }

          {:ok, %{status: 200}} ->
            %{
              status: :ok,
              message: "Connected, no data for test dates (normal if new). site_url=#{site_url}"
            }

          {:ok, %{status: 401}} ->
            %{status: :error, message: "Token invalid or expired — disconnect and reconnect"}

          {:ok, %{status: 403, body: b}} ->
            msg =
              if is_map(b), do: get_in(b, ["error", "message"]) || "Forbidden", else: "Forbidden"

            %{status: :error, message: "Access denied: #{msg}. site_url=#{site_url}"}

          {:ok, %{status: s, body: b}} ->
            detail =
              cond do
                is_map(b) ->
                  get_in(b, ["error", "message"]) ||
                    get_in(b, ["error", "errors", Access.at(0), "message"]) || inspect(b)

                is_binary(b) ->
                  String.slice(b, 0, 200)

                true ->
                  "HTTP #{s}"
              end

            %{status: :error, message: "HTTP #{s}: #{detail}. site_url=#{site_url}"}

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
                      {format_sync_ts(integration.last_synced_at, @user_tz)}
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
                    <%= if integration.platform in ["google_search_console", "bing_webmaster"] do %>
                      <button
                        phx-click="sync_test"
                        phx-value-id={integration.id}
                        class="inline-flex items-center px-2 py-1 text-xs font-medium rounded text-amber-700 bg-amber-50 hover:bg-amber-100 border border-amber-200"
                      >
                        Sync Test
                      </button>
                    <% end %>
                    <%= if integration.platform in ["google_search_console", "bing_webmaster"] do %>
                      <button
                        phx-click="backfill_search"
                        phx-value-id={integration.id}
                        data-confirm="Backfill 16 months of search data? This runs in the background."
                        class="inline-flex items-center px-2 py-1 text-xs font-medium rounded text-purple-700 bg-purple-50 hover:bg-purple-100 border border-purple-200"
                      >
                        Backfill 16mo
                      </button>
                    <% end %>
                    <%= if integration.platform in ["google_search_console", "bing_webmaster"] do %>
                      <button
                        phx-click="fix_gsc_url"
                        phx-value-id={integration.id}
                        class="inline-flex items-center px-2 py-1 text-xs font-medium rounded text-green-700 bg-green-50 hover:bg-green-100 border border-green-200"
                      >
                        Fix URL
                      </button>
                    <% end %>
                    <%= if integration.last_error do %>
                      <button
                        phx-click="clear_error"
                        phx-value-id={integration.id}
                        class="inline-flex items-center px-2 py-1 text-xs font-medium rounded text-gray-700 bg-gray-50 hover:bg-gray-100 border border-gray-200"
                      >
                        Clear Error
                      </button>
                    <% end %>
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
  defp platform_label("pinterest_ads"), do: "Pinterest"
  defp platform_label("reddit_ads"), do: "Reddit"
  defp platform_label("tiktok_ads"), do: "TikTok"
  defp platform_label("twitter_ads"), do: "X / Twitter"
  defp platform_label("linkedin_ads"), do: "LinkedIn"
  defp platform_label("snapchat_ads"), do: "Snapchat"
  defp platform_label("stripe"), do: "Stripe"
  defp platform_label("braintree"), do: "Braintree"
  defp platform_label("google_search_console"), do: "GSC"
  defp platform_label("bing_webmaster"), do: "Bing WMT"
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

  defp format_sync_ts(nil, _tz), do: "Never"

  defp format_sync_ts(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M %Z")
      _ -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end

  defp format_sync_ts(dt, _tz), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
