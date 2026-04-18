defmodule SpectabasWeb.Dashboard.SettingsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Site settings — domain, timezone, GDPR, tracking, ecommerce config."

  require Logger
  alias Spectabas.{Accounts, Sites}
  import SpectabasWeb.Dashboard.SidebarComponent

  # Events that modify site state. Viewers and analysts are blocked from
  # these via an attach_hook in mount — no per-handler guards needed.
  @settings_write_events ~w(save save_ai_config save_intent_config register_render_domain
    disconnect_ad backfill_payment_data backfill_search_console sync_ad_now
    save_ad_credentials clear_payment_data update_sync_frequency verify_dns)

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      changeset = Sites.Site.changeset(site, %{})

      socket =
        socket
        |> assign(:page_title, "Settings - #{site.name}")
        |> assign(:site, site)
        |> assign(:user, user)
        |> assign(:user_tz, user.timezone || "America/New_York")
        |> assign(:form, to_form(changeset))
        |> assign(:snippet, Sites.snippet_code(site))
        |> assign(:proxy_snippet, Sites.proxy_snippet_code(site))
        |> assign(:render_domain_status, check_render_domain(site.domain))
        |> assign(:ad_integrations, ensure_integrations(site))
        |> assign(:configuring_platform, nil)
        |> assign(:settings_tab, "general")

      # Block write events for viewers/analysts at the hook level — halts
      # event propagation before any handle_event clause runs.
      socket =
        if Accounts.can_manage_settings?(user) do
          socket
        else
          attach_hook(socket, :settings_guard, :handle_event, fn
            event, _params, sock ->
              if event in @settings_write_events do
                label = if user.role == :viewer, do: "Viewers", else: "Analysts"
                {:halt, put_flash(sock, :error, "#{label} cannot modify site settings.")}
              else
                {:cont, sock}
              end
          end)
        end

      {:ok, socket}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket)
      when tab in ~w(general content integrations advanced) do
    {:noreply, assign(socket, :settings_tab, tab)}
  end

  def handle_event("validate", %{"site" => params}, socket) do
    changeset =
      socket.assigns.site
      |> Sites.Site.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"site" => params}, socket) do
    case Sites.update_site(socket.assigns.site, params) do
      {:ok, site} ->
        changeset = Sites.Site.changeset(site, %{})

        {:noreply,
         socket
         |> put_flash(:info, "Settings updated.")
         |> assign(:site, site)
         |> assign(:form, to_form(changeset))
         |> assign(:snippet, Sites.snippet_code(site))
         |> assign(:proxy_snippet, Sites.proxy_snippet_code(site))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("save_ai_config", params, socket) do
    site = socket.assigns.site
    existing = Spectabas.AI.Config.get(site)

    # Only update api_key if a new one was provided (not the masked placeholder)
    api_key =
      case String.trim(params["api_key"] || "") do
        "" -> existing["api_key"] || ""
        new_key -> new_key
      end

    config = %{
      "provider" => params["provider"] || "none",
      "api_key" => api_key,
      "model" => params["model"]
    }

    if config["provider"] == "none" or config["api_key"] == "" do
      case Spectabas.AI.Config.save(site, config) do
        {:ok, updated_site} ->
          {:noreply,
           socket
           |> assign(:site, updated_site)
           |> put_flash(:info, "AI provider disabled.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save.")}
      end
    else
      # Validate the API key with a lightweight test call
      test_result = validate_ai_key(config["provider"], config["api_key"], config["model"])

      case test_result do
        :ok ->
          case Spectabas.AI.Config.save(site, config) do
            {:ok, updated_site} ->
              {:noreply,
               socket
               |> assign(:site, updated_site)
               |> put_flash(:info, "AI configuration saved and verified.")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to save AI configuration.")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "API key validation failed: #{reason}")}
      end
    end
  end

  def handle_event("save_intent_config", params, socket) do
    config = %{
      "buying_paths" => text_to_paths(params["buying_paths"]),
      "engaging_paths" => text_to_paths(params["engaging_paths"]),
      "support_paths" => text_to_paths(params["support_paths"]),
      "researching_threshold" => parse_threshold(params["researching_threshold"])
    }

    case Sites.update_site(socket.assigns.site, %{intent_config: config}) do
      {:ok, site} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intent classification updated.")
         |> assign(:site, site)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save intent config.")}
    end
  end

  def handle_event("register_render_domain", _params, socket) do
    domain = socket.assigns.site.domain

    case Sites.register_render_domain(domain) do
      :ok ->
        {:noreply,
         socket
         |> assign(:render_domain_status, :active)
         |> put_flash(:info, "Domain #{domain} registered on Render.")}

      {:ok, :already_exists} ->
        {:noreply,
         socket
         |> assign(:render_domain_status, :active)
         |> put_flash(:info, "Domain #{domain} already registered on Render.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to register: #{reason}")}
    end
  end

  def handle_event("disconnect_ad", %{"id" => id}, socket) do
    integration = authorize_integration!(id, socket)
    Spectabas.AdIntegrations.disconnect(integration)

    {:noreply,
     socket
     |> put_flash(:info, "#{platform_label(integration.platform)} disconnected.")
     |> assign(:ad_integrations, Spectabas.AdIntegrations.list_for_site(socket.assigns.site.id))}
  end

  def handle_event("backfill_payment_data", %{"id" => id, "days" => days}, socket) do
    integration = authorize_integration!(id, socket) |> Spectabas.Repo.preload(:site)

    num_days =
      case Integer.parse(days) do
        {n, _} when n > 0 and n <= 365 -> n
        _ -> 30
      end

    %{"integration_id" => integration.id, "num_days" => num_days}
    |> Spectabas.Workers.PaymentBackfill.new()
    |> Oban.insert()

    Process.send_after(self(), :refresh_integrations, 10_000)
    Process.send_after(self(), :refresh_integrations, 30_000)
    Process.send_after(self(), :refresh_integrations, 60_000)

    {:noreply,
     put_flash(
       socket,
       :info,
       "Backfill started for last #{num_days} days. Panels will update automatically."
     )}
  end

  def handle_event("backfill_search_console", %{"id" => id, "days" => days}, socket) do
    integration = authorize_integration!(id, socket)

    # GSC returns up to 16 months of data. Cap at 500 days to be safe.
    num_days =
      case Integer.parse(days) do
        {n, _} when n > 0 and n <= 500 -> n
        _ -> 90
      end

    %{"backfill_days" => num_days, "integration_id" => integration.id}
    |> Spectabas.Workers.SearchConsoleSync.new()
    |> Oban.insert()

    Process.send_after(self(), :refresh_integrations, 15_000)
    Process.send_after(self(), :refresh_integrations, 60_000)
    Process.send_after(self(), :refresh_integrations, 180_000)

    {:noreply,
     put_flash(
       socket,
       :info,
       "Search Console backfill started for last #{num_days} days. Chart data will populate as each day is fetched (~200ms/day + API latency). Refresh the Search Keywords page to see progress."
     )}
  end

  def handle_event("sync_ad_now", %{"id" => id}, socket) do
    integration = authorize_integration!(id, socket) |> Spectabas.Repo.preload(:site)

    case integration.platform do
      "stripe" ->
        Task.start(fn ->
          try do
            Spectabas.Workers.StripeSync.sync_now(integration)
          rescue
            e ->
              require Logger
              Logger.error("[SyncNow] Stripe sync failed: #{Exception.message(e)}")
          end
        end)

      "braintree" ->
        Task.start(fn ->
          try do
            Spectabas.Workers.BraintreeSync.sync_now(integration)
          rescue
            e ->
              require Logger
              Logger.error("[SyncNow] Braintree sync failed: #{Exception.message(e)}")
          end
        end)

      p when p in ["google_search_console", "bing_webmaster"] ->
        Task.start(fn ->
          try do
            Spectabas.Workers.SearchConsoleSync.sync_now(integration)
          rescue
            e ->
              require Logger
              Logger.error("[SyncNow] SearchConsole sync failed: #{Exception.message(e)}")
          end
        end)

      _ ->
        Oban.insert(Spectabas.Workers.AdSpendSyncOne.new(%{"integration_id" => integration.id}))
    end

    # Schedule panel refresh after sync completes
    Process.send_after(self(), :refresh_integrations, 5_000)
    Process.send_after(self(), :refresh_integrations, 15_000)
    Process.send_after(self(), :refresh_integrations, 30_000)

    {:noreply,
     socket
     |> put_flash(
       :info,
       "#{platform_label(integration.platform)} sync started. Panels will update automatically."
     )}
  end

  def handle_event("save_ad_credentials", %{"platform" => platform} = params, socket) do
    site = socket.assigns.site

    creds =
      case platform do
        "google_ads" ->
          %{
            "client_id" => params["client_id"] || "",
            "client_secret" => params["client_secret"] || "",
            "developer_token" => params["developer_token"] || ""
          }

        "bing_ads" ->
          %{
            "client_id" => params["client_id"] || "",
            "client_secret" => params["client_secret"] || "",
            "developer_token" => params["developer_token"] || ""
          }

        "meta_ads" ->
          %{
            "app_id" => params["app_id"] || "",
            "app_secret" => params["app_secret"] || ""
          }

        "stripe" ->
          %{
            "api_key" => params["api_key"] || ""
          }

        "braintree" ->
          %{
            "merchant_id" => params["merchant_id"] || "",
            "public_key" => params["public_key"] || "",
            "private_key" => params["private_key"] || ""
          }

        "google_search_console" ->
          %{
            "client_id" => params["client_id"] || "",
            "client_secret" => params["client_secret"] || ""
          }

        "bing_webmaster" ->
          %{
            "api_key" => params["api_key"] || ""
          }
      end

    # Don't overwrite saved credentials with empty values (masked form submits empty)
    existing = Spectabas.AdIntegrations.Credentials.get_for_platform(site, platform)

    require Logger

    Logger.info(
      "[CredSave] platform=#{platform} existing_keys=#{inspect(Map.keys(existing))} " <>
        "form_keys=#{inspect(for {k, v} <- creds, v != "", do: k)}"
    )

    creds =
      Enum.reduce(creds, existing, fn {k, v}, acc ->
        if v == "", do: acc, else: Map.put(acc, k, v)
      end)

    Logger.info(
      "[CredSave] merged_keys=#{inspect(Map.keys(creds))} has_api_key=#{creds["api_key"] != nil and creds["api_key"] != ""}"
    )

    # Validate Stripe/Braintree keys before saving
    validation =
      cond do
        platform == "stripe" and creds["api_key"] != "" ->
          validate_stripe_key(creds["api_key"])

        true ->
          :ok
      end

    case validation do
      {:error, msg} ->
        {:noreply, put_flash(socket, :error, "Invalid API key: #{msg}")}

      :ok ->
        case Spectabas.AdIntegrations.Credentials.save(site, platform, creds) do
          {:ok, updated_site} ->
            Spectabas.Audit.log("ad_credentials.saved", %{
              user_id: socket.assigns.current_scope.user.id,
              site_id: site.id,
              platform: platform
            })

            # For Stripe/Braintree, also create/update the integration record directly (no OAuth flow)
            socket =
              cond do
                platform == "stripe" and creds["api_key"] != "" ->
                  # Delete any existing revoked integration first to avoid conflicts
                  existing =
                    Enum.find(
                      Spectabas.AdIntegrations.list_for_site(site.id),
                      &(&1.platform == "stripe")
                    )

                  if existing && existing.status == "revoked" do
                    Spectabas.Repo.delete(existing)
                  end

                  case Spectabas.AdIntegrations.connect(site.id, "stripe", %{
                         access_token: creds["api_key"],
                         refresh_token: "",
                         account_id: "",
                         account_name: "Stripe"
                       }) do
                    {:ok, _} ->
                      :ok

                    {:error, reason} ->
                      Logger.error("[CredSave] Stripe connect failed: #{inspect(reason)}")
                  end

                  assign(
                    socket,
                    :ad_integrations,
                    Spectabas.AdIntegrations.list_for_site(site.id)
                  )

                platform == "braintree" and creds["merchant_id"] != "" ->
                  existing =
                    Enum.find(
                      Spectabas.AdIntegrations.list_for_site(site.id),
                      &(&1.platform == "braintree")
                    )

                  if existing && existing.status == "revoked" do
                    Spectabas.Repo.delete(existing)
                  end

                  case Spectabas.AdIntegrations.connect(site.id, "braintree", %{
                         access_token: creds["merchant_id"],
                         refresh_token: "",
                         account_id: creds["merchant_id"],
                         account_name: "Braintree"
                       }) do
                    {:ok, _} ->
                      :ok

                    {:error, reason} ->
                      Logger.error("[CredSave] Braintree connect failed: #{inspect(reason)}")
                  end

                  assign(
                    socket,
                    :ad_integrations,
                    Spectabas.AdIntegrations.list_for_site(site.id)
                  )

                platform == "bing_webmaster" and creds["api_key"] != "" ->
                  existing =
                    Enum.find(
                      Spectabas.AdIntegrations.list_for_site(site.id),
                      &(&1.platform == "bing_webmaster")
                    )

                  if existing && existing.status == "revoked" do
                    Spectabas.Repo.delete(existing)
                  end

                  # Use user-provided site_url, fall back to auto-derived domain
                  bing_site_url =
                    case String.trim(creds["site_url"] || "") do
                      "" -> Spectabas.Sites.parent_domain_for(site)
                      url -> url
                    end

                  case Spectabas.AdIntegrations.connect(site.id, "bing_webmaster", %{
                         access_token: creds["api_key"],
                         refresh_token: "",
                         account_id: bing_site_url,
                         account_name: bing_site_url,
                         extra: %{"site_url" => bing_site_url}
                       }) do
                    {:ok, _} ->
                      :ok

                    {:error, reason} ->
                      Logger.error("[CredSave] Bing Webmaster connect failed: #{inspect(reason)}")
                  end

                  assign(
                    socket,
                    :ad_integrations,
                    Spectabas.AdIntegrations.list_for_site(site.id)
                  )

                true ->
                  socket
              end

            {:noreply,
             socket
             |> put_flash(:info, "#{platform_label(platform)} credentials saved.")
             |> assign(:site, updated_site)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to save credentials.")}
        end
    end
  end

  def handle_event("clear_payment_data", %{"id" => id}, socket) do
    integration = authorize_integration!(id, socket) |> Spectabas.Repo.preload(:site)
    site_id = integration.site_id
    site_p = Spectabas.ClickHouse.param(site_id)

    # Delete only data imported by this specific integration
    platform_p = Spectabas.ClickHouse.param(integration.platform)

    ecom_result =
      Spectabas.ClickHouse.execute(
        "ALTER TABLE ecommerce_events DELETE WHERE site_id = #{site_p} AND import_source = #{platform_p}"
      )

    # Delete subscription snapshots only for this platform's source
    # (prevents Stripe clear from wiping Braintree subscriptions)
    sub_result =
      if integration.platform in ["stripe", "braintree"] do
        # subscription_events doesn't have import_source, so scope by subscription_id prefix
        # Stripe subs start with "sub_", Braintree with different prefixes
        # For now, delete all for the site since we only support one payment provider's subs
        Spectabas.ClickHouse.execute(
          "ALTER TABLE subscription_events DELETE WHERE site_id = #{site_p}"
        )
      else
        :ok
      end

    # Clear search data if this is a search integration
    search_result =
      case integration.platform do
        "google_search_console" ->
          Spectabas.ClickHouse.execute(
            "ALTER TABLE search_console DELETE WHERE site_id = #{site_p} AND source = 'google'"
          )

        "bing_webmaster" ->
          Spectabas.ClickHouse.execute(
            "ALTER TABLE search_console DELETE WHERE site_id = #{site_p} AND source = 'bing'"
          )

        _ ->
          :ok
      end

    # Clear ad spend data if this is an ad platform
    _ad_result =
      if integration.platform in ["google_ads", "bing_ads", "meta_ads"] do
        Spectabas.ClickHouse.execute(
          "ALTER TABLE ad_spend DELETE WHERE site_id = #{site_p} AND platform = #{platform_p}"
        )
      else
        :ok
      end

    # Reset last_synced_at so next sync starts fresh
    Spectabas.AdIntegrations.mark_synced(integration)

    Spectabas.Audit.log("integration_data.cleared", %{
      user_id: socket.assigns.current_scope.user.id,
      site_id: site_id,
      platform: integration.platform,
      ecom_result: inspect(ecom_result),
      sub_result: inspect(sub_result),
      search_result: inspect(search_result)
    })

    {:noreply,
     socket
     |> put_flash(
       :info,
       "#{platform_label(integration.platform)} data cleared. ClickHouse DELETE is async — data will disappear within a few minutes."
     )}
  end

  def handle_event(
        "update_sync_frequency",
        %{"integration_id" => id, "frequency" => freq},
        socket
      ) do
    integration = authorize_integration!(id, socket)
    minutes = String.to_integer(freq)

    case Spectabas.AdIntegrations.update_sync_frequency(integration, minutes) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Sync frequency updated.")
         |> assign(
           :ad_integrations,
           Spectabas.AdIntegrations.list_for_site(socket.assigns.site.id)
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update sync frequency.")}
    end
  end

  def handle_event("toggle_ad_config", %{"platform" => platform}, socket) do
    current = socket.assigns[:configuring_platform]
    new = if current == platform, do: nil, else: platform
    {:noreply, assign(socket, :configuring_platform, new)}
  end

  def handle_event("verify_dns", _params, socket) do
    site = socket.assigns.site

    case Spectabas.Sites.DNSVerifier.verify_site(site) do
      {:ok, :verified} ->
        site = Sites.get_site!(site.id)

        {:noreply,
         socket
         |> assign(:site, site)
         |> put_flash(:info, "DNS verified for #{site.domain}")}

      {:ok, :unverified} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "DNS not verified. Add a CNAME record pointing #{site.domain} to www.spectabas.com"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "DNS check failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:refresh_integrations, socket) do
    integrations = Spectabas.AdIntegrations.list_for_site(socket.assigns.site.id)
    {:noreply, assign(socket, :ad_integrations, integrations)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Settings"
      page_description="Configure tracking, GDPR mode, and custom domains."
      active="settings"
      live_visitors={0}
    >
      <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Site Settings</h1>
        </div>

        <div class="border-b border-gray-200 mb-6">
          <nav class="flex gap-2 sm:gap-4 overflow-x-auto">
            <button
              :for={
                {key, label} <- [
                  {"general", "General"},
                  {"content", "Content"},
                  {"integrations", "Integrations"},
                  {"advanced", "Advanced"}
                ]
              }
              phx-click="switch_tab"
              phx-value-tab={key}
              class={[
                "pb-3 text-sm font-medium border-b-2 -mb-px whitespace-nowrap",
                if(@settings_tab == key,
                  do: "border-indigo-600 text-indigo-700",
                  else: "border-transparent text-gray-500 hover:text-gray-700"
                )
              ]}
            >
              {label}
            </button>
          </nav>
        </div>

        <%!-- Tracking Snippet --%>
        <div :if={@settings_tab == "advanced"} class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Tracking Snippet</h2>

          <div class="mb-5">
            <h3 class="text-sm font-medium text-gray-700 mb-2">Standard (direct)</h3>
            <p class="text-xs text-gray-500 mb-2">
              Uses the analytics subdomain directly. Add to your site's
              <code class="bg-gray-100 px-1 rounded text-xs">&lt;head&gt;</code>
              tag.
            </p>
            <div class="relative">
              <pre class="bg-gray-900 text-gray-100 rounded-lg p-4 text-sm overflow-x-auto"><code><%= @snippet %></code></pre>
              <button
                id="copy-snippet-btn"
                data-text={@snippet}
                phx-click={
                  JS.dispatch("spectabas:clipcopy", to: "#copy-snippet-btn")
                  |> JS.set_attribute({"data-copied", "true"}, to: "#copy-snippet-btn")
                }
                class="absolute top-2 right-2 px-3 py-1 bg-gray-700 text-white rounded text-xs hover:bg-gray-600"
              >
                Copy
              </button>
            </div>
          </div>

          <div>
            <h3 class="text-sm font-medium text-gray-700 mb-2">
              Proxy mode (Cloudflare)
              <span class="ml-1 text-xs font-normal text-gray-400">
                — recommended for ad blocker evasion
              </span>
            </h3>
            <p class="text-xs text-gray-500 mb-2">
              Routes tracking through your main domain via a Cloudflare Worker. Bypasses most ad blockers.
            </p>
            <div class="relative">
              <pre class="bg-gray-900 text-gray-100 rounded-lg p-4 text-sm overflow-x-auto"><code><%= @proxy_snippet %></code></pre>
              <button
                id="copy-proxy-btn"
                data-text={@proxy_snippet}
                phx-click={
                  JS.dispatch("spectabas:clipcopy", to: "#copy-proxy-btn")
                  |> JS.set_attribute({"data-copied", "true"}, to: "#copy-proxy-btn")
                }
                class="absolute top-2 right-2 px-3 py-1 bg-gray-700 text-white rounded text-xs hover:bg-gray-600"
              >
                Copy
              </button>
            </div>
            <p class="mt-2 text-xs text-gray-500">
              Requires a Cloudflare Worker on your domain.
              <.link
                navigate={~p"/docs/getting-started#ad-blocker-evasion"}
                class="text-indigo-600 hover:text-indigo-800 font-medium"
              >
                Cloudflare Worker setup guide &rarr;
              </.link>
            </p>
          </div>
        </div>

        <%!-- Settings Form --%>
        <div :if={@settings_tab != "integrations"} class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-6">Configuration</h2>
          <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-6">
            <div :if={@settings_tab == "general"} class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div>
                <label class="block text-sm font-medium text-gray-700">Site Name</label>
                <input
                  type="text"
                  name="site[name]"
                  value={@form[:name].value}
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Domain</label>
                <input
                  type="text"
                  name="site[domain]"
                  value={@form[:domain].value}
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                />
                <div class="mt-2 flex flex-wrap items-center gap-2">
                  <span class={[
                    "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium",
                    if(@site.dns_verified,
                      do: "bg-green-100 text-green-700",
                      else: "bg-yellow-100 text-yellow-700"
                    )
                  ]}>
                    <span class={"w-1.5 h-1.5 rounded-full " <> if(@site.dns_verified, do: "bg-green-500", else: "bg-yellow-500")} />
                    {if @site.dns_verified, do: "DNS Verified", else: "DNS Pending"}
                  </span>
                  <button phx-click="verify_dns" class="text-xs text-indigo-600 hover:text-indigo-800">
                    Check
                  </button>
                  <span class={[
                    "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium",
                    case @render_domain_status do
                      :active -> "bg-green-100 text-green-700"
                      :not_found -> "bg-yellow-100 text-yellow-700"
                      _ -> "bg-gray-100 text-gray-600"
                    end
                  ]}>
                    <span class={"w-1.5 h-1.5 rounded-full " <> case @render_domain_status do
                    :active -> "bg-green-500"
                    :not_found -> "bg-yellow-500"
                    _ -> "bg-gray-400"
                  end} />
                    {case @render_domain_status do
                      :active -> "Render Active"
                      :not_found -> "Render Pending"
                      _ -> "Render Unknown"
                    end}
                  </span>
                  <button
                    :if={@render_domain_status != :active}
                    phx-click="register_render_domain"
                    class="text-xs text-indigo-600 hover:text-indigo-800"
                  >
                    Register
                  </button>
                </div>
                <p :if={!@site.dns_verified} class="mt-1 text-xs text-yellow-600">
                  CNAME {@site.domain} &rarr; www.spectabas.com
                </p>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Timezone</label>
                <select
                  name="site[timezone]"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                >
                  <option
                    :for={
                      tz <-
                        ~w(UTC US/Eastern US/Central US/Mountain US/Pacific Europe/London Europe/Paris Europe/Berlin Asia/Tokyo Asia/Shanghai Australia/Sydney Pacific/Auckland America/New_York America/Chicago America/Denver America/Los_Angeles America/Toronto America/Sao_Paulo)
                    }
                    value={tz}
                    selected={@form[:timezone].value == tz}
                  >
                    {tz}
                  </option>
                </select>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Retention Days</label>
                <input
                  type="number"
                  name="site[retention_days]"
                  value={@form[:retention_days].value}
                  min="30"
                  max="3650"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                />
              </div>
            </div>

            <div :if={@settings_tab == "general"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-4">Privacy</h3>
              <div class="space-y-4">
                <div class="flex items-center gap-3">
                  <input type="hidden" name="site[gdpr_mode]" value="off" />
                  <input
                    type="checkbox"
                    name="site[gdpr_mode]"
                    value="on"
                    checked={@form[:gdpr_mode].value == "on"}
                    class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded"
                  />
                  <label class="text-sm text-gray-700">
                    GDPR Mode (cookieless, IP anonymization)
                  </label>
                </div>
                <div>
                  <label class="block text-sm font-medium text-gray-700">Cookie Domain</label>
                  <input
                    type="text"
                    name="site[cookie_domain]"
                    value={@form[:cookie_domain].value}
                    placeholder=".example.com"
                    class="mt-1 block w-full md:w-1/2 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                  />
                  <p class="mt-1.5 text-xs text-gray-500">
                    Set this to share cookies across subdomains. Use a leading dot (e.g. <code class="bg-gray-100 px-1 rounded">.example.com</code>)
                    to match all subdomains like
                    <code class="bg-gray-100 px-1 rounded">www.example.com</code>
                    and <code class="bg-gray-100 px-1 rounded">app.example.com</code>.
                    Wildcards (<code class="bg-gray-100 px-1 rounded">*.example.com</code>) are not supported — use the dot prefix instead.
                    Leave blank to restrict cookies to the exact analytics subdomain.
                  </p>
                </div>
              </div>
            </div>

            <div :if={@settings_tab == "general"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-4">
                Allowed Domains &amp; Cross-Domain Tracking
              </h3>
              <p class="text-sm text-gray-500 mb-4">
                The parent domain of your analytics subdomain (e.g.
                <code class="bg-gray-100 px-1 rounded">dogbreederlicensing.org</code>
                and <code class="bg-gray-100 px-1 rounded">www.dogbreederlicensing.org</code>) is automatically allowed to send analytics data.
                Add additional domains below if you have other sites that should also be allowed to send data to this analytics endpoint.
                Enable cross-domain tracking to share visitor sessions across these domains.
              </p>
              <div class="space-y-4">
                <div class="flex items-center gap-3">
                  <input type="hidden" name="site[cross_domain_tracking]" value="false" />
                  <input
                    type="checkbox"
                    name="site[cross_domain_tracking]"
                    value="true"
                    checked={
                      @form[:cross_domain_tracking].value == true ||
                        @form[:cross_domain_tracking].value == "true"
                    }
                    class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded"
                  />
                  <label class="text-sm text-gray-700">
                    Enable cross-domain tracking (share sessions across domains)
                  </label>
                </div>
                <div>
                  <label class="block text-sm font-medium text-gray-700">
                    Additional Allowed Domains (comma-separated)
                  </label>
                  <input
                    type="text"
                    name="site[cross_domain_sites_text]"
                    value={Enum.join(@site.cross_domain_sites, ", ")}
                    class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                    placeholder="app.example.com, shop.example.com"
                  />
                  <p class="mt-1.5 text-xs text-gray-500">
                    Only needed for domains beyond the parent domain. For example, if your analytics subdomain is <code class="bg-gray-100 px-1 rounded">b.example.com</code>, then
                    <code class="bg-gray-100 px-1 rounded">example.com</code>
                    and <code class="bg-gray-100 px-1 rounded">www.example.com</code>
                    are already allowed automatically.
                  </p>
                </div>
              </div>
            </div>

            <div :if={@settings_tab == "advanced"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-4">IP Filtering</h3>
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="block text-sm font-medium text-gray-700">
                    IP Allowlist (one per line)
                  </label>
                  <textarea
                    name="site[ip_allowlist_text]"
                    rows="3"
                    class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                    placeholder="1.2.3.4&#10;5.6.7.0/24"
                  ><%= Enum.join(@site.ip_allowlist, "\n") %></textarea>
                </div>
                <div>
                  <label class="block text-sm font-medium text-gray-700">
                    IP Blocklist (one per line)
                  </label>
                  <textarea
                    name="site[ip_blocklist_text]"
                    rows="3"
                    class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                    placeholder="10.0.0.1&#10;192.168.0.0/16"
                  ><%= Enum.join(@site.ip_blocklist, "\n") %></textarea>
                </div>
              </div>
            </div>

            <div :if={@settings_tab == "content"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-2">Site Search</h3>
              <p class="text-xs text-gray-500 mb-3">
                URL query parameters that indicate an internal site search. When a pageview
                URL contains one of these parameters, its value is captured as the search query
                on the <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/search"}
                  class="text-indigo-600 underline"
                >Site Search page</.link>. One parameter name per line. Leave blank to use defaults
                (<span class="font-mono">q</span>, <span class="font-mono">query</span>, <span class="font-mono">search</span>, <span class="font-mono">s</span>, <span class="font-mono">keyword</span>).
              </p>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Search query parameters
                </label>
                <textarea
                  name="site[search_query_params_text]"
                  rows="3"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                  placeholder="q&#10;query&#10;search&#10;s&#10;keyword"
                ><%= Enum.join(@site.search_query_params || [], "\n") %></textarea>
              </div>
            </div>

            <div :if={@settings_tab == "content"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-2">Scraper Detection</h3>
              <p class="text-xs text-gray-500 mb-3">
                URL path prefixes that identify "content" on your site. Drives the
                systematic-crawl signal on the <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/scrapers"}
                  class="text-indigo-600 underline"
                >Scrapers page</.link>. One prefix per line. Example: <span class="font-mono">/listings</span>, <span class="font-mono">/profiles</span>.
              </p>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Content path prefixes
                </label>
                <textarea
                  name="site[scraper_content_prefixes_text]"
                  rows="3"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                  placeholder="/listings&#10;/profiles&#10;/content"
                ><%= Enum.join(@site.scraper_content_prefixes || [], "\n") %></textarea>
              </div>
            </div>

            <div :if={@settings_tab == "content"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-2">Visitor Journeys</h3>
              <p class="text-xs text-gray-500 mb-3">
                Pages that count as conversions for the <.link
                  navigate={~p"/dashboard/sites/#{@site.id}/journeys"}
                  class="text-indigo-600 underline"
                >Journeys page</.link>. One URL path per line. Paths are matched as prefixes
                (e.g. <span class="font-mono">/contact</span>
                matches <span class="font-mono">/contact</span>
                and <span class="font-mono">/contact/thank-you</span>).
              </p>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Conversion pages
                </label>
                <textarea
                  name="site[journey_conversion_pages_text]"
                  rows="3"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                  placeholder="/contact&#10;/checkout&#10;/signup"
                ><%= Enum.join(@site.journey_conversion_pages || [], "\n") %></textarea>
              </div>
            </div>

            <div :if={@settings_tab == "content"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-2">Identity Cookie</h3>
              <p class="text-xs text-gray-500 mb-3">
                If your site sets its own cookie to identify logged-in users (e.g. <span class="font-mono">_puppies_fp</span>), enter the cookie name here.
                The tracker will read it and use the value to merge visitor profiles when
                a user clears their <span class="font-mono">_sab</span> cookie or switches
                browsers. Only used in GDPR-off mode. Leave blank to disable.
              </p>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Cookie name
                </label>
                <input
                  type="text"
                  name="site[identity_cookie_name]"
                  value={@site.identity_cookie_name}
                  placeholder="_puppies_fp"
                  class="mt-1 block w-64 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                />
              </div>
            </div>

            <div :if={@settings_tab == "advanced"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-2">Scraper Webhooks</h3>
              <p class="text-xs text-gray-500 mb-3">
                Automatically POST to your endpoint when a visitor is flagged as a scraper.
                The webhook fires once per visitor when they first cross the detection threshold,
                and again if their score escalates significantly.
              </p>
              <div class="space-y-3">
                <div class="flex items-center gap-3">
                  <input type="hidden" name="site[scraper_webhook_enabled]" value="false" />
                  <input
                    type="checkbox"
                    name="site[scraper_webhook_enabled]"
                    value="true"
                    checked={@form[:scraper_webhook_enabled].value}
                    class="h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  <label class="text-sm font-medium text-gray-700">Enable scraper webhooks</label>
                </div>
                <div>
                  <label class="block text-sm font-medium text-gray-700">Webhook URL</label>
                  <input
                    type="url"
                    name="site[scraper_webhook_url]"
                    value={@form[:scraper_webhook_url].value}
                    placeholder="https://yourapp.com/api/webhooks/spectabas/scraper"
                    class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                  />
                  <p class="mt-1 text-xs text-gray-400">
                    Full URL to POST to. Deactivations go to
                    <span class="font-mono">/deactivate</span>
                    on the same path.
                  </p>
                </div>
                <div>
                  <label class="block text-sm font-medium text-gray-700">Webhook Secret</label>
                  <input
                    type="text"
                    name="site[scraper_webhook_secret]"
                    value={@form[:scraper_webhook_secret].value}
                    placeholder="shared bearer token"
                    autocomplete="off"
                    class="mt-1 block w-64 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5 font-mono text-xs"
                  />
                  <p class="mt-1 text-xs text-gray-400">
                    Sent as <span class="font-mono">Authorization: Bearer &lt;secret&gt;</span>
                  </p>
                </div>
              </div>
            </div>

            <div :if={@settings_tab == "advanced"} class="border-t border-gray-200 pt-6">
              <h3 class="text-base font-medium text-gray-900 mb-4">Ecommerce</h3>
              <div class="flex items-center gap-3">
                <input type="hidden" name="site[ecommerce_enabled]" value="false" />
                <input
                  type="checkbox"
                  name="site[ecommerce_enabled]"
                  value="true"
                  checked={
                    @form[:ecommerce_enabled].value == true ||
                      @form[:ecommerce_enabled].value == "true"
                  }
                  class="h-4 w-4 text-indigo-600 focus:ring-indigo-500 border-gray-300 rounded"
                />
                <label class="text-sm text-gray-700">Enable ecommerce tracking</label>
              </div>
              <div
                :if={
                  @form[:ecommerce_enabled].value == true || @form[:ecommerce_enabled].value == "true"
                }
                class="mt-4"
              >
                <label class="block text-sm font-medium text-gray-700">Currency</label>
                <select
                  name="site[currency]"
                  class="mt-1 block w-full md:w-48 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                >
                  <option
                    :for={c <- ["USD", "EUR", "GBP", "CAD", "AUD", "JPY"]}
                    value={c}
                    selected={@form[:currency].value == c}
                  >
                    {c}
                  </option>
                </select>
              </div>
            </div>

            <div class="border-t border-gray-200 pt-6 flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
              >
                Save Settings
              </button>
            </div>
          </.form>
        </div>

        <%!-- AI Provider Configuration --%>
        <div :if={@settings_tab == "content"} class="bg-white rounded-lg shadow p-6 mt-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-1">AI Analysis</h2>
          <p class="text-sm text-gray-500 mb-4">
            Configure an AI provider for automated insights and weekly analysis emails.
          </p>
          <% ai_config = Spectabas.AI.Config.get(@site) %>
          <form phx-submit="save_ai_config" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700">Provider</label>
                <select
                  name="provider"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <option value="none" selected={ai_config["provider"] in [nil, "none"]}>None</option>
                  <%= for {key, %{label: label}} <- Spectabas.AI.Config.providers() do %>
                    <option value={key} selected={ai_config["provider"] == key}>{label}</option>
                  <% end %>
                </select>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">API Key</label>
                <input
                  type="password"
                  name="api_key"
                  value=""
                  placeholder={
                    if ai_config["api_key"],
                      do: mask_credential(ai_config["api_key"]),
                      else: "API Key"
                  }
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">Model</label>
                <select
                  name="model"
                  class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                >
                  <%= for {key, %{models: models}} <- Spectabas.AI.Config.providers() do %>
                    <%= for {model_id, model_label} <- models do %>
                      <option value={model_id} selected={ai_config["model"] == model_id}>
                        {model_label}
                      </option>
                    <% end %>
                  <% end %>
                </select>
              </div>
            </div>
            <button
              type="submit"
              class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
            >
              Save AI Configuration
            </button>
          </form>
        </div>

        <%!-- Visitor Intent Configuration --%>
        <div :if={@settings_tab == "content"} class="bg-white rounded-lg shadow p-6 mt-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-1">Visitor Intent Classification</h2>
          <p class="text-sm text-gray-500 mb-4">
            Customize which URL paths trigger each intent badge. One path fragment per line (matches anywhere in the URL).
          </p>
          <form phx-submit="save_intent_config" class="space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Buying paths <span class="text-gray-400 font-normal">(conversion pages)</span>
                </label>
                <textarea
                  name="buying_paths"
                  rows="4"
                  class="block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
                  placeholder="/pricing&#10;/checkout&#10;/subscribe"
                >{paths_to_text((@site.intent_config || %{})["buying_paths"])}</textarea>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Engaging paths <span class="text-gray-400 font-normal">(core app features)</span>
                </label>
                <textarea
                  name="engaging_paths"
                  rows="4"
                  class="block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
                  placeholder="/search&#10;/listings&#10;/messages"
                >{paths_to_text((@site.intent_config || %{})["engaging_paths"])}</textarea>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Support paths <span class="text-gray-400 font-normal">(help/contact pages)</span>
                </label>
                <textarea
                  name="support_paths"
                  rows="4"
                  class="block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
                  placeholder="/help&#10;/contact&#10;/faq"
                >{paths_to_text((@site.intent_config || %{})["support_paths"])}</textarea>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Researching threshold <span class="text-gray-400 font-normal">(min pageviews)</span>
                </label>
                <input
                  type="number"
                  name="researching_threshold"
                  value={(@site.intent_config || %{})["researching_threshold"] || 2}
                  min="2"
                  max="10"
                  class="block w-24 rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
                <p class="text-[10px] text-gray-400 mt-1">
                  Sessions with this many+ pageviews classified as "researching"
                </p>
              </div>
            </div>
            <div class="flex justify-end">
              <button
                type="submit"
                class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
              >
                Save Intent Config
              </button>
            </div>
          </form>
        </div>

        <%!-- Ad Integrations --%>
        <div :if={@settings_tab == "integrations"} class="bg-white rounded-lg shadow p-6 mt-6">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold text-gray-900">Integrations</h2>
            <.link
              navigate="/docs/conversions#integration-overview"
              class="text-sm text-indigo-600 hover:text-indigo-800 font-medium"
            >
              Setup guide &rarr;
            </.link>
          </div>
          <p class="text-sm text-gray-600 mb-5">
            Connect ad accounts for ROAS tracking, or Stripe for automatic revenue import.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
            <%= for {platform, label, icon_color, doc_anchor} <- [
              {"google_ads", "Google Ads", "bg-blue-100 text-blue-700", "/docs/conversions#google-ads-setup"},
              {"bing_ads", "Microsoft Ads", "bg-amber-100 text-amber-700", "/docs/conversions#bing-ads-setup"},
              {"meta_ads", "Meta Ads", "bg-purple-100 text-purple-700", "/docs/conversions#meta-ads-setup"},
              {"stripe", "Stripe", "bg-indigo-100 text-indigo-700", "/docs/admin#stripe-setup"},
              {"braintree", "Braintree", "bg-teal-100 text-teal-700", "/docs/admin#braintree-setup"},
              {"google_search_console", "Google Search Console", "bg-green-100 text-green-700", "/docs/admin#search-console-setup"},
              {"bing_webmaster", "Bing Webmaster", "bg-cyan-100 text-cyan-700", "/docs/admin#bing-webmaster-setup"}
            ] do %>
              <% integration =
                Enum.find(@ad_integrations, &(&1.platform == platform && &1.status == "active")) %>
              <div class="border border-gray-200 rounded-lg p-5">
                <div class="flex items-center justify-between mb-3">
                  <div class="flex items-center gap-2">
                    <span class={"inline-flex items-center px-2.5 py-1 rounded-lg text-sm font-semibold #{icon_color}"}>
                      {label}
                    </span>
                    <%= if integration do %>
                      <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-700">
                        Connected
                      </span>
                    <% end %>
                  </div>
                </div>

                <%= if integration do %>
                  <div class="text-sm text-gray-600 space-y-1.5 mb-4">
                    <div :if={integration.account_name && integration.account_name != ""}>
                      <span class="text-gray-500">Account:</span>
                      <span class="font-medium text-gray-800">{integration.account_name}</span>
                    </div>
                    <div :if={integration.last_synced_at}>
                      <span class="text-gray-500">Last sync:</span>
                      <span class="font-medium">
                        {format_sync_ts(integration.last_synced_at, @user_tz)}
                      </span>
                    </div>
                    <div :if={!integration.last_synced_at && !integration.last_error}>
                      <span class="text-amber-600 font-medium">
                        Waiting for first sync — click Sync Now
                      </span>
                    </div>
                    <div :if={integration.last_error} class="text-red-600 font-medium">
                      Error: {String.slice(integration.last_error || "", 0, 80)}
                    </div>
                    <form phx-change="update_sync_frequency" class="flex items-center gap-2 mt-1">
                      <input type="hidden" name="integration_id" value={integration.id} />
                      <span class="text-gray-500">Sync every</span>
                      <select
                        name="frequency"
                        class="text-sm rounded border-gray-300 py-1 pr-8"
                      >
                        <%= for {mins, lbl} <- [{5, "5 min"}, {15, "15 min"}, {30, "30 min"}, {60, "1 hour"}, {360, "6 hours"}, {1440, "24 hours"}] do %>
                          <option
                            value={mins}
                            selected={Spectabas.AdIntegrations.sync_frequency(integration) == mins}
                          >
                            {lbl}
                          </option>
                        <% end %>
                      </select>
                    </form>
                  </div>
                  <div class="flex items-center gap-3 mt-3">
                    <button
                      phx-click="sync_ad_now"
                      phx-value-id={integration.id}
                      class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-indigo-700 bg-indigo-50 hover:bg-indigo-100 border border-indigo-200"
                    >
                      Sync Now
                    </button>
                    <%= if platform in ["stripe", "braintree"] do %>
                      <button
                        phx-click="backfill_payment_data"
                        phx-value-id={integration.id}
                        phx-value-days="90"
                        data-confirm={"Backfill last 90 days of #{label} data? This runs in the background and may take a few minutes."}
                        class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-green-700 bg-green-50 hover:bg-green-100 border border-green-200"
                      >
                        Backfill 90d
                      </button>
                      <button
                        phx-click="clear_payment_data"
                        phx-value-id={integration.id}
                        data-confirm={"Clear ALL imported #{label} data for this site? Only deletes data imported from #{label} — API transactions are NOT affected. This cannot be undone."}
                        class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-amber-700 bg-amber-50 hover:bg-amber-100 border border-amber-200"
                      >
                        Clear Data
                      </button>
                    <% end %>
                    <%= if platform in ["google_search_console", "bing_webmaster"] do %>
                      <button
                        phx-click="backfill_search_console"
                        phx-value-id={integration.id}
                        phx-value-days="90"
                        data-confirm={"Backfill last 90 days of #{label} data? This runs in the background and takes ~30 seconds for 90 days (one request per day with a small pause between)."}
                        class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-green-700 bg-green-50 hover:bg-green-100 border border-green-200"
                      >
                        Backfill 90d
                      </button>
                      <button
                        phx-click="backfill_search_console"
                        phx-value-id={integration.id}
                        phx-value-days="480"
                        data-confirm={"Backfill last 16 months of #{label} data (the maximum Google returns)? This runs in the background and takes ~2-3 minutes."}
                        class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-emerald-700 bg-emerald-50 hover:bg-emerald-100 border border-emerald-200"
                      >
                        Backfill 16mo
                      </button>
                    <% end %>
                    <button
                      phx-click="disconnect_ad"
                      phx-value-id={integration.id}
                      data-confirm={"Disconnect #{label}? Data sync will stop."}
                      class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-lg text-red-700 bg-red-50 hover:bg-red-100 border border-red-200"
                    >
                      Disconnect
                    </button>
                  </div>
                <% else %>
                  <div class="flex items-center gap-3 flex-wrap">
                    <%= if ad_platform_configured?(@site, platform) and platform != "stripe" do %>
                      <a
                        href={ad_authorize_url(platform, @site)}
                        class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
                      >
                        Connect {label}
                      </a>
                    <% end %>
                    <button
                      phx-click="toggle_ad_config"
                      phx-value-platform={platform}
                      class={"inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg border shadow-sm " <>
                        if(@configuring_platform == platform,
                          do: "text-gray-700 bg-gray-100 border-gray-300 hover:bg-gray-200",
                          else: "text-indigo-700 bg-white border-indigo-200 hover:bg-indigo-50"
                        )}
                    >
                      {if @configuring_platform == platform, do: "Hide", else: "Configure"}
                    </button>
                  </div>
                <% end %>

                <%!-- Credential Configuration Form --%>
                <%= if @configuring_platform == platform do %>
                  <form
                    phx-submit="save_ad_credentials"
                    class="mt-4 space-y-4 border-t border-gray-200 pt-4"
                  >
                    <input type="hidden" name="platform" value={platform} />
                    <% creds = Spectabas.AdIntegrations.Credentials.get_for_platform(@site, platform) %>
                    <p class="text-sm text-gray-600">
                      <%= case platform do %>
                        <% "google_ads" -> %>
                          Get credentials from
                          <a
                            href="https://console.cloud.google.com/apis/credentials"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >
                            Google Cloud Console
                          </a>
                          and your developer token from <a
                            href="https://ads.google.com/aw/apicenter"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >Google Ads API Center</a>.
                        <% "bing_ads" -> %>
                          Register an app in
                          <a
                            href="https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >
                            Azure Portal
                          </a>
                          and get your developer token from <a
                            href="https://developers.ads.microsoft.com"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >Microsoft Advertising</a>.
                        <% "meta_ads" -> %>
                          Create an app at <a
                            href="https://developers.facebook.com/apps"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >Meta for Developers</a>. See
                          <a
                            href="/docs/conversions#integration-overview"
                            class="text-indigo-600 underline"
                          >
                            setup guide
                          </a>
                          for details.
                        <% "stripe" -> %>
                          Find your secret key in the
                          <a
                            href="https://dashboard.stripe.com/apikeys"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >
                            Stripe Dashboard
                          </a>
                          &gt; Developers &gt; API keys. Use the key starting with
                          <code>sk_live_</code>
                          or <code>rk_live_</code>.
                        <% "braintree" -> %>
                          Find credentials in the
                          <a
                            href="https://www.braintreegateway.com/login"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >
                            Braintree Control Panel
                          </a>
                          &gt; Settings &gt; API. You need Merchant ID, Public Key, and Private Key.
                        <% "google_search_console" -> %>
                          Use the same OAuth Client ID and Secret as Google Ads.
                          Add redirect URI:
                          <code class="text-xs bg-gray-100 px-1 rounded">
                            https://www.spectabas.com/auth/ad/google_search_console/callback
                          </code>
                          and enable the Search Console API.
                          <a href="/docs/admin#search-console-setup" class="text-indigo-600 underline">
                            Full setup guide
                          </a>
                        <% "bing_webmaster" -> %>
                          Get your API key from
                          <a
                            href="https://www.bing.com/webmasters/apikey"
                            target="_blank"
                            class="text-indigo-600 underline"
                          >
                            Bing Webmaster Tools
                          </a>
                          &gt; Settings &gt; API access.
                      <% end %>
                    </p>
                    <a
                      href={doc_anchor}
                      target="_blank"
                      class="inline-flex items-center text-sm text-indigo-600 hover:text-indigo-800 font-medium mb-2"
                    >
                      View full setup guide &rarr;
                    </a>
                    <%= cond do %>
                      <% platform in ["google_ads", "bing_ads", "google_search_console"] -> %>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">Client ID</label>
                          <input
                            type="text"
                            name="client_id"
                            value=""
                            placeholder={
                              if creds["client_id"],
                                do: mask_credential(creds["client_id"]),
                                else: "Client ID"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                            placeholder="e.g. 123456789.apps.googleusercontent.com"
                          />
                        </div>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">Client Secret</label>
                          <input
                            type="password"
                            name="client_secret"
                            value=""
                            placeholder={
                              if creds["client_secret"],
                                do: mask_credential(creds["client_secret"]),
                                else: "Client Secret"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                            placeholder="OAuth client secret"
                          />
                        </div>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">
                            Developer Token
                          </label>
                          <input
                            type="password"
                            name="developer_token"
                            value=""
                            placeholder={
                              if creds["developer_token"],
                                do: mask_credential(creds["developer_token"]),
                                else: "Developer Token"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                            placeholder="API developer token"
                          />
                        </div>
                      <% platform == "stripe" -> %>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">
                            Stripe Secret Key
                          </label>
                          <input
                            type="password"
                            name="api_key"
                            value=""
                            placeholder={
                              if creds["api_key"],
                                do: mask_credential(creds["api_key"]),
                                else: "sk_live_..."
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                            placeholder="sk_live_..."
                          />
                          <p class="mt-1 text-xs text-gray-500">
                            Found in Stripe Dashboard &gt; Developers &gt; API keys. Use the secret key (starts with sk_live_).
                          </p>
                        </div>
                      <% platform == "braintree" -> %>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">Merchant ID</label>
                          <input
                            type="text"
                            name="merchant_id"
                            value=""
                            placeholder={
                              if creds["merchant_id"],
                                do: mask_credential(creds["merchant_id"]),
                                else: "Merchant ID"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                          />
                        </div>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">Public Key</label>
                          <input
                            type="text"
                            name="public_key"
                            value=""
                            placeholder={
                              if creds["public_key"],
                                do: mask_credential(creds["public_key"]),
                                else: "Public Key"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                          />
                        </div>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">Private Key</label>
                          <input
                            type="password"
                            name="private_key"
                            value=""
                            placeholder={
                              if creds["private_key"],
                                do: mask_credential(creds["private_key"]),
                                else: "Private Key"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                          />
                        </div>
                      <% platform == "bing_webmaster" -> %>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">
                            Site URL (as registered in Bing Webmaster Tools)
                          </label>
                          <input
                            type="text"
                            name="site_url"
                            value=""
                            placeholder={
                              if creds["site_url"],
                                do: creds["site_url"],
                                else: "e.g., roommates.com"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                          />
                          <p class="mt-1 text-xs text-gray-400">
                            Enter the exact domain as shown in your Bing Webmaster Tools dashboard.
                          </p>
                        </div>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">
                            Bing Webmaster API Key
                          </label>
                          <input
                            type="password"
                            name="api_key"
                            value=""
                            placeholder={
                              if creds["api_key"],
                                do: mask_credential(creds["api_key"]),
                                else: "API Key"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                          />
                        </div>
                      <% true -> %>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">App ID</label>
                          <input
                            type="text"
                            name="app_id"
                            value=""
                            placeholder={
                              if creds["app_id"], do: mask_credential(creds["app_id"]), else: "App ID"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                            placeholder="e.g. 1234567890"
                          />
                        </div>
                        <div>
                          <label class="block text-sm font-medium text-gray-700">App Secret</label>
                          <input
                            type="password"
                            name="app_secret"
                            value=""
                            placeholder={
                              if creds["app_secret"],
                                do: mask_credential(creds["app_secret"]),
                                else: "App Secret"
                            }
                            class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2"
                            placeholder="Meta app secret"
                          />
                        </div>
                    <% end %>
                    <button
                      type="submit"
                      class="w-full inline-flex justify-center items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
                    >
                      Save Credentials
                    </button>
                  </form>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  # Validate a Stripe API key by making a lightweight API call
  # Validate using Charges endpoint (only needs Charges:Read, which all valid keys have)
  defp validate_stripe_key(key) do
    require Logger

    # Log first/last 4 chars for debugging (never log the full key)
    key_hint =
      if byte_size(key) > 8,
        do: String.slice(key, 0, 8) <> "..." <> String.slice(key, -4, 4),
        else: "(short key)"

    Logger.info("[StripeValidation] Validating key #{key_hint}, length=#{byte_size(key)}")

    result =
      Req.get("https://api.stripe.com/v1/charges?limit=1",
        headers: [
          {"authorization", "Bearer #{key}"},
          {"stripe-version", "2024-12-18.acacia"}
        ]
      )

    case result do
      {:ok, %{status: 200}} ->
        Logger.info("[StripeValidation] Key valid")
        :ok

      {:ok, %{status: status, body: body}} ->
        msg =
          if is_map(body),
            do: get_in(body, ["error", "message"]) || "HTTP #{status}",
            else: "HTTP #{status}"

        Logger.warning("[StripeValidation] Failed: status=#{status}, msg=#{msg}")
        {:error, "Stripe says: #{msg}"}

      {:error, reason} ->
        Logger.error("[StripeValidation] Request failed: #{inspect(reason)}")
        {:error, "Could not reach Stripe: #{inspect(reason)}"}
    end
  end

  defp validate_ai_key("anthropic", key, _model) do
    case Req.post("https://api.anthropic.com/v1/messages",
           body:
             Jason.encode!(%{
               model: "claude-haiku-4-5-20251001",
               max_tokens: 1,
               messages: [%{role: "user", content: "hi"}]
             }),
           headers: [
             {"x-api-key", key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401}} ->
        {:error, "Invalid API key"}

      {:ok, %{status: s, body: b}} ->
        {:error, get_in(b, ["error", "message"]) || "HTTP #{s}"}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason) |> String.slice(0, 100)}"}
    end
  end

  defp validate_ai_key("openai", key, _model) do
    case Req.get("https://api.openai.com/v1/models",
           headers: [{"authorization", "Bearer #{key}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 401}} ->
        {:error, "Invalid API key"}

      {:ok, %{status: s, body: b}} ->
        {:error, get_in(b, ["error", "message"]) || "HTTP #{s}"}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason) |> String.slice(0, 100)}"}
    end
  end

  defp validate_ai_key("google", key, _model) do
    case Req.get("https://generativelanguage.googleapis.com/v1beta/models?key=#{key}",
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400}} ->
        {:error, "Invalid API key"}

      {:ok, %{status: s, body: b}} ->
        {:error,
         if(is_map(b), do: get_in(b, ["error", "message"]) || "HTTP #{s}", else: "HTTP #{s}")}

      {:error, reason} ->
        {:error, "Connection failed: #{inspect(reason) |> String.slice(0, 100)}"}
    end
  end

  defp validate_ai_key(_, _, _), do: {:error, "Unknown provider"}

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
  defp platform_label("google_search_console"), do: "Google Search Console"
  defp platform_label("bing_webmaster"), do: "Bing Webmaster"
  defp platform_label(p), do: p

  # Mask saved credentials — show first 4 + last 4 chars with dots in between
  # Auto-create integration records if credentials exist but integration is missing/revoked.
  # This repairs the state when credentials are saved but the integration record was lost.
  defp ensure_integrations(site) do
    require Logger
    integrations = Spectabas.AdIntegrations.list_for_site(site.id)

    # Fix payment integrations stuck in "error" status back to "active"
    # Only for Stripe/Braintree — ad platforms (Google/Bing/Meta) may be in "error" for
    # legitimate reasons (expired token, revoked access) and need manual reconnection.
    Enum.each(integrations, fn i ->
      if i.status == "error" and i.platform in ["stripe", "braintree"] do
        i
        |> Spectabas.AdIntegrations.AdIntegration.changeset(%{status: "active"})
        |> Spectabas.Repo.update()
      end
    end)

    Enum.each(["stripe", "braintree", "bing_webmaster"], fn platform ->
      creds = Spectabas.AdIntegrations.Credentials.get_for_platform(site, platform)
      has_active = Enum.any?(integrations, &(&1.platform == platform and &1.status == "active"))

      key =
        case platform do
          "stripe" -> creds["api_key"]
          "braintree" -> creds["merchant_id"]
          "bing_webmaster" -> creds["api_key"]
        end

      if key not in [nil, ""] and not has_active do
        # Delete any revoked records first
        Enum.filter(integrations, &(&1.platform == platform and &1.status == "revoked"))
        |> Enum.each(&Spectabas.Repo.delete/1)

        token = if platform == "stripe", do: key, else: key

        case Spectabas.AdIntegrations.connect(site.id, platform, %{
               access_token: token,
               refresh_token: "",
               account_id: if(platform == "braintree", do: key, else: ""),
               account_name: String.capitalize(platform)
             }) do
          {:ok, _} ->
            Logger.info("[Settings] Auto-repaired #{platform} integration for site #{site.id}")

          {:error, reason} ->
            Logger.warning("[Settings] Failed to auto-repair #{platform}: #{inspect(reason)}")
        end
      end
    end)

    # Return fresh list
    Spectabas.AdIntegrations.list_for_site(site.id)
  end

  # Verify integration belongs to the current site (prevents IDOR via crafted WebSocket events)
  defp authorize_integration!(id, socket) do
    integration = Spectabas.AdIntegrations.get!(id)

    if integration.site_id != socket.assigns.site.id do
      raise "Unauthorized: integration #{id} does not belong to site #{socket.assigns.site.id}"
    end

    integration
  end

  defp mask_credential(nil), do: ""
  defp mask_credential(""), do: ""

  defp mask_credential(val) when byte_size(val) > 8 do
    String.slice(val, 0, 4) <> "••••••••" <> String.slice(val, -4, 4)
  end

  defp mask_credential(_), do: "••••••••"

  defp ad_authorize_url(platform, site) do
    state = Phoenix.Token.sign(SpectabasWeb.Endpoint, "ad_oauth", site.id)

    case platform do
      "google_ads" ->
        Spectabas.AdIntegrations.Platforms.GoogleAds.authorize_url(site, state)

      "bing_ads" ->
        Spectabas.AdIntegrations.Platforms.BingAds.authorize_url(site, state)

      "meta_ads" ->
        Spectabas.AdIntegrations.Platforms.MetaAds.authorize_url(site, state)

      "google_search_console" ->
        Spectabas.AdIntegrations.Platforms.GoogleSearchConsole.authorize_url(site, state)

      _ ->
        "#"
    end
  end

  defp ad_platform_configured?(site, platform) do
    Spectabas.AdIntegrations.Credentials.configured?(site, platform)
  end

  defp check_render_domain(domain) do
    case Sites.list_render_domains() do
      {:ok, domains} ->
        if domain in domains, do: :active, else: :not_found

      {:error, _} ->
        :unknown
    end
  end

  defp paths_to_text(nil), do: ""
  defp paths_to_text(paths) when is_list(paths), do: Enum.join(paths, "\n")
  defp paths_to_text(_), do: ""

  defp text_to_paths(nil), do: []

  defp text_to_paths(text) do
    text
    |> String.split(~r/[\n,]+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_threshold(nil), do: 2

  defp parse_threshold(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n >= 2 -> n
      _ -> 2
    end
  end

  defp parse_threshold(val) when is_integer(val) and val >= 2, do: val
  defp parse_threshold(_), do: 2

  defp format_sync_ts(nil, _tz), do: "Never"

  defp format_sync_ts(%DateTime{} = dt, tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, local} -> Calendar.strftime(local, "%Y-%m-%d %H:%M %Z")
      _ -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end

  defp format_sync_ts(dt, _tz), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
