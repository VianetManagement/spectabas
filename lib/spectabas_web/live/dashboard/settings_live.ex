defmodule SpectabasWeb.Dashboard.SettingsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Site settings — domain, timezone, GDPR, tracking, ecommerce config."

  alias Spectabas.{Accounts, Sites}
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok,
       socket
       |> put_flash(:error, "Unauthorized")
       |> redirect(to: ~p"/")}
    else
      changeset = Sites.Site.changeset(site, %{})

      {:ok,
       socket
       |> assign(:page_title, "Settings - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:form, to_form(changeset))
       |> assign(:snippet, Sites.snippet_code(site))
       |> assign(:render_domain_status, check_render_domain(site.domain))
       |> assign(:example_html, example_html(site))
       |> assign(:ad_integrations, Spectabas.AdIntegrations.list_for_site(site.id))
       |> assign(:configuring_platform, nil)}
    end
  end

  @impl true
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
         |> assign(:snippet, Sites.snippet_code(site))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
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
    integration = Spectabas.AdIntegrations.get!(id)
    Spectabas.AdIntegrations.disconnect(integration)

    {:noreply,
     socket
     |> put_flash(:info, "#{platform_label(integration.platform)} disconnected.")
     |> assign(:ad_integrations, Spectabas.AdIntegrations.list_for_site(socket.assigns.site.id))}
  end

  def handle_event("sync_ad_now", %{"id" => id}, socket) do
    integration = Spectabas.AdIntegrations.get!(id) |> Spectabas.Repo.preload(:site)

    if integration.platform == "stripe" do
      Task.start(fn -> Spectabas.Workers.StripeSync.sync_now(integration) end)
    else
      Oban.insert(Spectabas.Workers.AdSpendSyncOne.new(%{"integration_id" => integration.id}))
    end

    {:noreply,
     socket
     |> put_flash(
       :info,
       "#{platform_label(integration.platform)} sync queued. Refresh in a minute to see results."
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
      end

    # Don't overwrite saved credentials with empty values (masked form submits empty)
    existing = Spectabas.AdIntegrations.Credentials.get_for_platform(site, platform)

    creds =
      Enum.reduce(creds, existing, fn {k, v}, acc ->
        if v == "", do: acc, else: Map.put(acc, k, v)
      end)

    case Spectabas.AdIntegrations.Credentials.save(site, platform, creds) do
      {:ok, updated_site} ->
        Spectabas.Audit.log("ad_credentials.saved", %{
          user_id: socket.assigns.current_scope.user.id,
          site_id: site.id,
          platform: platform
        })

        # For Stripe, also create/update the integration record directly (no OAuth flow)
        socket =
          if platform == "stripe" and creds["api_key"] != "" do
            api_key = creds["api_key"]

            {:ok, _integration} =
              Spectabas.AdIntegrations.connect(site.id, "stripe", %{
                access_token: api_key,
                refresh_token: "",
                account_id: "",
                account_name: "Stripe"
              })

            socket
            |> assign(:ad_integrations, Spectabas.AdIntegrations.list_for_site(site.id))
          else
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

        <p
          :if={msg = Phoenix.Flash.get(@flash, :info)}
          class="rounded-lg bg-blue-50 p-3 text-sm text-blue-700 mb-6"
        >
          {msg}
        </p>
        <p
          :if={msg = Phoenix.Flash.get(@flash, :error)}
          class="rounded-lg bg-red-50 p-3 text-sm text-red-700 mb-6"
        >
          {msg}
        </p>

        <%!-- Tracking Snippet --%>
        <div class="bg-white rounded-lg shadow p-6 mb-8">
          <h2 class="text-lg font-semibold text-gray-900 mb-4">Tracking Snippet</h2>
          <p class="text-sm text-gray-600 mb-2">
            Copy and paste this snippet into the
            <code class="bg-gray-100 px-1.5 py-0.5 rounded text-xs font-mono">&lt;head&gt;</code>
            section of every page you want to track. It should go before the closing
            <code class="bg-gray-100 px-1.5 py-0.5 rounded text-xs font-mono">&lt;/head&gt;</code>
            tag.
          </p>
          <div class="relative mt-4">
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
          <div class="mt-4 bg-gray-50 rounded-lg p-4 text-sm text-gray-600">
            <p class="font-medium text-gray-700 mb-2">Example placement:</p>
            <pre class="text-xs font-mono text-gray-500 overflow-x-auto"><code>{@example_html}</code></pre>
            <p class="mt-3 text-xs text-gray-500">
              The script loads asynchronously and won't slow down your page.
              If you use a CMS or site builder, look for a "Custom HTML" or "Header Scripts" setting.
            </p>
          </div>
        </div>

        <%!-- Settings Form --%>
        <div class="bg-white rounded-lg shadow p-6">
          <h2 class="text-lg font-semibold text-gray-900 mb-6">Configuration</h2>
          <.form for={@form} phx-submit="save" phx-change="validate" class="space-y-6">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
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

            <div class="border-t border-gray-200 pt-6">
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

            <div class="border-t border-gray-200 pt-6">
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

            <div class="border-t border-gray-200 pt-6">
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

            <div class="border-t border-gray-200 pt-6">
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
                class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
              >
                Save Settings
              </button>
            </div>
          </.form>
        </div>

        <%!-- Visitor Intent Configuration --%>
        <div class="bg-white rounded-lg shadow p-6 mt-6">
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
                  class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
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
                  class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
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
                  class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
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
                  class="block w-24 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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
        <div class="bg-white rounded-lg shadow p-6 mt-6">
          <div class="flex items-center justify-between mb-3">
            <h2 class="text-lg font-semibold text-gray-900">Integrations</h2>
            <.link
              navigate="/docs/admin#ad-integrations"
              class="text-sm text-indigo-600 hover:text-indigo-800 font-medium"
            >
              Setup guide &rarr;
            </.link>
          </div>
          <p class="text-sm text-gray-600 mb-5">
            Connect ad accounts for ROAS tracking, or Stripe for automatic revenue import.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
            <%= for {platform, label, icon_color} <- [
              {"google_ads", "Google Ads", "bg-blue-100 text-blue-700"},
              {"bing_ads", "Microsoft Ads", "bg-amber-100 text-amber-700"},
              {"meta_ads", "Meta Ads", "bg-purple-100 text-purple-700"},
              {"stripe", "Stripe", "bg-indigo-100 text-indigo-700"}
            ] do %>
              <% integration =
                Enum.find(@ad_integrations, &(&1.platform == platform && &1.status == "active")) %>
              <div class="border border-gray-200 rounded-lg p-5">
                <div class="flex items-center justify-between mb-3">
                  <div class="flex items-center gap-2">
                    <span class={"inline-flex items-center px-2.5 py-1 rounded-md text-sm font-semibold #{icon_color}"}>
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
                        {Calendar.strftime(integration.last_synced_at, "%Y-%m-%d %H:%M")} UTC
                      </span>
                    </div>
                    <div :if={!integration.last_synced_at && !integration.last_error}>
                      <span class="text-amber-600 font-medium">
                        Waiting for first sync (every 6h, or click Sync Now)
                      </span>
                    </div>
                    <div :if={integration.last_error} class="text-red-600 font-medium">
                      Error: {String.slice(integration.last_error || "", 0, 80)}
                    </div>
                  </div>
                  <div class="flex items-center gap-3">
                    <button
                      phx-click="sync_ad_now"
                      phx-value-id={integration.id}
                      class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-md text-indigo-700 bg-indigo-50 hover:bg-indigo-100 border border-indigo-200"
                    >
                      Sync Now
                    </button>
                    <button
                      phx-click="disconnect_ad"
                      phx-value-id={integration.id}
                      data-confirm={"Disconnect #{label}? Data sync will stop."}
                      class="inline-flex items-center px-3 py-1.5 text-sm font-medium rounded-md text-red-700 bg-red-50 hover:bg-red-100 border border-red-200"
                    >
                      Disconnect
                    </button>
                  </div>
                <% else %>
                  <div class="flex items-center gap-3 flex-wrap">
                    <%= if ad_platform_configured?(@site, platform) and platform != "stripe" do %>
                      <a
                        href={ad_authorize_url(platform, @site)}
                        class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 shadow-sm"
                      >
                        Connect {label}
                      </a>
                    <% end %>
                    <button
                      phx-click="toggle_ad_config"
                      phx-value-platform={platform}
                      class={"inline-flex items-center px-4 py-2 text-sm font-medium rounded-md border shadow-sm " <>
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
                          <a href="/docs/admin#ad-integrations" class="text-indigo-600 underline">
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
                          &gt; Developers &gt; API keys. Use the key starting with <code>sk_live_</code>.
                      <% end %>
                    </p>
                    <%= cond do %>
                      <% platform in ["google_ads", "bing_ads"] -> %>
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

  defp platform_label("google_ads"), do: "Google Ads"
  defp platform_label("bing_ads"), do: "Microsoft Ads"
  defp platform_label("meta_ads"), do: "Meta Ads"
  defp platform_label("stripe"), do: "Stripe"
  defp platform_label(p), do: p

  # Mask saved credentials — show first 4 + last 4 chars with dots in between
  defp mask_credential(nil), do: ""
  defp mask_credential(""), do: ""

  defp mask_credential(val) when byte_size(val) > 8 do
    String.slice(val, 0, 4) <> "••••••••" <> String.slice(val, -4, 4)
  end

  defp mask_credential(_), do: "••••••••"

  defp ad_authorize_url(platform, site) do
    state = Phoenix.Token.sign(SpectabasWeb.Endpoint, "ad_oauth", site.id)

    case platform do
      "google_ads" -> Spectabas.AdIntegrations.Platforms.GoogleAds.authorize_url(site, state)
      "bing_ads" -> Spectabas.AdIntegrations.Platforms.BingAds.authorize_url(site, state)
      "meta_ads" -> Spectabas.AdIntegrations.Platforms.MetaAds.authorize_url(site, state)
      _ -> "#"
    end
  end

  defp ad_platform_configured?(site, platform) do
    Spectabas.AdIntegrations.Credentials.configured?(site, platform)
  end

  defp example_html(site) do
    snippet = Sites.snippet_code(site)

    """
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8">
        <title>Your Website</title>

        <!-- Spectabas Analytics -->
        #{snippet}
      </head>
      <body>
        ...
      </body>
    </html>\
    """
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
end
