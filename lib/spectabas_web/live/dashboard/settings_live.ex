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
       |> assign(:copied, false)}
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

      <%!-- DNS Status --%>
      <div class={[
        "rounded-lg p-4 mb-8",
        if(@site.dns_verified,
          do: "bg-green-50 border border-green-200",
          else: "bg-yellow-50 border border-yellow-200"
        )
      ]}>
        <div class="flex items-center gap-2">
          <span :if={@site.dns_verified} class="text-green-700 font-medium">DNS Verified</span>
          <span :if={!@site.dns_verified} class="text-yellow-700 font-medium">DNS Not Verified</span>
          <span :if={@site.dns_verified_at} class="text-sm text-gray-500">
            (verified {Calendar.strftime(@site.dns_verified_at, "%Y-%m-%d %H:%M")})
          </span>
        </div>
      </div>

      <%!-- Tracking Snippet --%>
      <div class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Tracking Snippet</h2>
        <p class="text-sm text-gray-500 mb-4">
          Add this snippet to the <code class="bg-gray-100 px-1 rounded">&lt;head&gt;</code>
          of your website.
        </p>
        <div class="relative">
          <pre class="bg-gray-900 text-gray-100 rounded-lg p-4 text-sm overflow-x-auto"><code><%= @snippet %></code></pre>
          <button
            phx-click="copy_snippet"
            id="copy-snippet-btn"
            phx-hook="CopyToClipboard"
            data-text={@snippet}
            class="absolute top-2 right-2 px-3 py-1 bg-gray-700 text-white rounded text-xs hover:bg-gray-600"
          >
            {if @copied, do: "Copied!", else: "Copy"}
          </button>
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
end
