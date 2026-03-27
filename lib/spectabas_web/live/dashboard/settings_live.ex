defmodule SpectabasWeb.Dashboard.SettingsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites}

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
       |> assign(:copied, false)
       |> assign(:render_domain_status, check_render_domain(site.domain))
       |> assign(:example_html, example_html(site))}
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

  def handle_event("copy_snippet", _params, socket) do
    {:noreply, assign(socket, :copied, true)}
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
    <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.link
          navigate={~p"/dashboard/sites/#{@site.id}"}
          class="text-sm text-indigo-600 hover:text-indigo-800"
        >
          &larr; Back to {@site.name}
        </.link>
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

      <%!-- DNS Status --%>
      <div class={[
        "rounded-lg p-4 mb-8",
        if(@site.dns_verified,
          do: "bg-green-50 border border-green-200",
          else: "bg-yellow-50 border border-yellow-200"
        )
      ]}>
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span :if={@site.dns_verified} class="text-green-700 font-medium">DNS Verified</span>
            <span :if={!@site.dns_verified} class="text-yellow-700 font-medium">
              DNS Not Verified
            </span>
            <span :if={@site.dns_verified_at} class="text-sm text-gray-500">
              (verified {Calendar.strftime(@site.dns_verified_at, "%Y-%m-%d %H:%M")})
            </span>
          </div>
          <button
            phx-click="verify_dns"
            class="text-sm px-3 py-1.5 rounded-md border border-gray-300 bg-white text-gray-700 hover:bg-gray-50"
          >
            Verify DNS
          </button>
        </div>
        <p :if={!@site.dns_verified} class="mt-2 text-sm text-yellow-700">
          Add a CNAME record: <code class="bg-yellow-100 px-1 rounded">{@site.domain}</code>
          &rarr; <code class="bg-yellow-100 px-1 rounded">www.spectabas.com</code>
        </p>
      </div>

      <%!-- Render Domain Status --%>
      <div class={[
        "rounded-lg p-4 mb-8",
        case @render_domain_status do
          :active -> "bg-green-50 border border-green-200"
          :not_found -> "bg-yellow-50 border border-yellow-200"
          _ -> "bg-gray-50 border border-gray-200"
        end
      ]}>
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span :if={@render_domain_status == :active} class="text-green-700 font-medium">
              Render Domain Active
            </span>
            <span :if={@render_domain_status == :not_found} class="text-yellow-700 font-medium">
              Render Domain Not Registered
            </span>
            <span :if={@render_domain_status == :unknown} class="text-gray-600 font-medium">
              Render Domain Status Unknown
            </span>
          </div>
          <button
            :if={@render_domain_status != :active}
            phx-click="register_render_domain"
            class="text-sm px-3 py-1.5 rounded-md border border-gray-300 bg-white text-gray-700 hover:bg-gray-50"
          >
            Register on Render
          </button>
        </div>
      </div>

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
            phx-click="copy_snippet"
            id="copy-snippet-btn"
            data-text={@snippet}
            onclick="navigator.clipboard.writeText(this.dataset.text)"
            class="absolute top-2 right-2 px-3 py-1 bg-gray-700 text-white rounded text-xs hover:bg-gray-600"
          >
            {if @copied, do: "Copied!", else: "Copy"}
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
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Domain</label>
              <input
                type="text"
                name="site[domain]"
                value={@form[:domain].value}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Timezone</label>
              <input
                type="text"
                name="site[timezone]"
                value={@form[:timezone].value}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Retention Days</label>
              <input
                type="number"
                name="site[retention_days]"
                value={@form[:retention_days].value}
                min="30"
                max="3650"
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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
                  class="mt-1 block w-full md:w-1/2 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                />
              </div>
            </div>
          </div>

          <div class="border-t border-gray-200 pt-6">
            <h3 class="text-base font-medium text-gray-900 mb-4">Cross-Domain Tracking</h3>
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
                <label class="text-sm text-gray-700">Enable cross-domain tracking</label>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700">
                  Allowed Domains (comma-separated)
                </label>
                <input
                  type="text"
                  name="site[cross_domain_sites_text]"
                  value={Enum.join(@site.cross_domain_sites, ", ")}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
                  placeholder="other-site.com, app.example.com"
                />
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
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm font-mono text-xs"
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
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm font-mono text-xs"
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
                  @form[:ecommerce_enabled].value == true || @form[:ecommerce_enabled].value == "true"
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
                class="mt-1 block w-full md:w-48 rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm"
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
