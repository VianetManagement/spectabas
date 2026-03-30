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
       |> load_report_subscription()}
    end
  end

  defp load_report_subscription(socket) do
    user = socket.assigns.user
    site = socket.assigns.site
    sub = Spectabas.Reports.get_email_subscription(user, site)

    report_freq = if sub, do: to_string(sub.frequency), else: "off"
    report_hour = if sub, do: sub.send_hour, else: 9

    socket
    |> assign(:report_frequency, report_freq)
    |> assign(:report_hour, report_hour)
    |> assign(:report_subscribers, Spectabas.Reports.list_email_subscriptions_for_site(site))
  end

  @impl true
  def handle_event("validate", %{"site" => params}, socket) do
    changeset =
      socket.assigns.site
      |> Sites.Site.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save_report", %{"report" => params}, socket) do
    user = socket.assigns.user
    site = socket.assigns.site

    case Spectabas.Reports.upsert_email_subscription(user, site, params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email report preferences saved.")
         |> load_report_subscription()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save report preferences.")}
    end
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
      </div>

      <%!-- Email Reports --%>
      <div class="bg-white rounded-lg shadow p-6 mt-8">
        <h2 class="text-lg font-semibold text-gray-900 mb-2">Email Reports</h2>
        <p class="text-sm text-gray-500 mb-6">
          Receive periodic analytics summaries for this site by email. This is a personal preference for your account.
        </p>
        <form phx-submit="save_report" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Frequency</label>
              <select
                name="report[frequency]"
                class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              >
                <option value="off" selected={@report_frequency == "off"}>Off</option>
                <option value="daily" selected={@report_frequency == "daily"}>Daily</option>
                <option value="weekly" selected={@report_frequency == "weekly"}>Weekly</option>
                <option value="monthly" selected={@report_frequency == "monthly"}>Monthly</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Send Time</label>
              <select
                name="report[send_hour]"
                class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              >
                <option :for={h <- 0..23} value={h} selected={@report_hour == h}>
                  {String.pad_leading(to_string(h), 2, "0")}:00
                </option>
              </select>
              <p class="mt-1 text-xs text-gray-500">
                In the site's timezone ({@site.timezone || "UTC"})
              </p>
            </div>
          </div>
          <div class="flex justify-end">
            <button
              type="submit"
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
            >
              Save Report Preferences
            </button>
          </div>
        </form>

        <div :if={@report_subscribers != []} class="mt-8 border-t border-gray-200 pt-6">
          <h3 class="text-sm font-medium text-gray-900 mb-3">Report Subscribers</h3>
          <table class="min-w-full text-sm">
            <thead>
              <tr class="text-left text-xs font-medium text-gray-500 uppercase">
                <th class="py-2">User</th>
                <th class="py-2">Frequency</th>
                <th class="py-2">Send Time</th>
                <th class="py-2">Last Sent</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <tr :for={sub <- @report_subscribers}>
                <td class="py-2 text-gray-900">{sub.user.email}</td>
                <td class="py-2 text-gray-600 capitalize">{sub.frequency}</td>
                <td class="py-2 text-gray-600">
                  {String.pad_leading(to_string(sub.send_hour), 2, "0")}:00
                </td>
                <td class="py-2 text-gray-500">{sub.last_sent_at || "Never"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </.dashboard_layout>
    """
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
end
