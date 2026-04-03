defmodule SpectabasWeb.Admin.SitesLive do
  use SpectabasWeb, :live_view

  alias Spectabas.Sites

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    sites = Spectabas.Accounts.accessible_sites(user)

    account =
      if user.account_id,
        do: Spectabas.Accounts.get_account!(user.account_id),
        else: nil

    {:ok,
     socket
     |> assign(:page_title, "Manage Sites")
     |> assign(:sites, sites)
     |> assign(:account, account)
     |> assign(:show_form, false)
     |> assign(:form, to_form(site_changeset()))}
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  def handle_event("validate_site", %{"site" => params}, socket) do
    changeset =
      %Sites.Site{}
      |> Sites.Site.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create_site", %{"site" => params}, socket) do
    user = socket.assigns.current_scope.user

    if not Spectabas.Accounts.can_create_site?(user) do
      {:noreply, put_flash(socket, :error, "Site limit reached for this account.")}
    else
      # Inject account_id into params
      params = Map.put(params, "account_id", user.account_id)

      case Sites.create_site(params) do
        {:ok, site} ->
          render_msg =
            case Sites.register_render_domain(site.domain) do
              :ok -> " Custom domain #{site.domain} registered on Render."
              {:ok, :already_exists} -> " Domain #{site.domain} already registered on Render."
              {:error, reason} -> " Warning: failed to register domain on Render: #{reason}"
            end

          sites = Spectabas.Accounts.accessible_sites(user)

          {:noreply,
           socket
           |> put_flash(
             :info,
             "Site created.#{render_msg} Add a CNAME for #{site.domain} → www.spectabas.com"
           )
           |> assign(:sites, sites)
           |> assign(:show_form, false)
           |> assign(:form, to_form(site_changeset()))}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    end
  end

  def handle_event("register_domain", %{"domain" => domain}, socket) do
    case Sites.register_render_domain(domain) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Domain #{domain} registered on Render.")}

      {:ok, :already_exists} ->
        {:noreply, put_flash(socket, :info, "Domain #{domain} already registered on Render.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to register #{domain}: #{reason}")}
    end
  end

  def handle_event("delete_site", %{"id" => site_id}, socket) do
    admin = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    case Sites.delete_site(admin, site) do
      {:ok, _} ->
        sites = Sites.list_sites()
        {:noreply, socket |> put_flash(:info, "Site deleted.") |> assign(:sites, sites)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete site: #{inspect(reason)}")}
    end
  end

  defp site_changeset do
    Sites.Site.changeset(%Sites.Site{}, %{})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <div>
          <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
            &larr; Admin Dashboard
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Sites</h1>
        </div>
        <button
          phx-click="toggle_form"
          class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
        >
          {if @show_form, do: "Cancel", else: "New Site"}
        </button>
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

      <div :if={@show_form} class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Create Site</h2>
        <.form for={@form} phx-submit="create_site" phx-change="validate_site" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-gray-700">Site Name</label>
              <input
                type="text"
                name="site[name]"
                value={@form[:name].value}
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                required
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Domain</label>
              <input
                type="text"
                name="site[domain]"
                value={@form[:domain].value}
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                placeholder="example.com"
                required
              />
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
                  selected={(@form[:timezone].value || "UTC") == tz}
                >
                  {tz}
                </option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">GDPR Mode</label>
              <select
                name="site[gdpr_mode]"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
              >
                <option value="on" selected={@form[:gdpr_mode].value == "on"}>On (cookieless)</option>
                <option value="off" selected={@form[:gdpr_mode].value == "off"}>Off</option>
              </select>
            </div>
          </div>
          <div class="flex justify-end">
            <button
              type="submit"
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
            >
              Create Site
            </button>
          </div>
        </.form>
        <div class="mt-4 p-4 bg-blue-50 rounded-lg">
          <p class="text-sm text-blue-800">
            After creating the site, add a CNAME DNS record pointing your domain to <code class="bg-blue-100 px-1 rounded">www.spectabas.com</code>,
            then install the tracking snippet on your website.
          </p>
        </div>
      </div>

      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Name
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Domain
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                DNS
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                GDPR
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Status
              </th>
              <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
                Actions
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :if={@sites == []}>
              <td colspan="6" class="px-6 py-8 text-center text-gray-500">No sites yet.</td>
            </tr>
            <tr :for={site <- @sites} class="hover:bg-gray-50">
              <td class="px-6 py-4 text-sm font-medium text-gray-900">
                <.link
                  navigate={~p"/dashboard/sites/#{site.id}"}
                  class="text-indigo-600 hover:text-indigo-800"
                >
                  {site.name}
                </.link>
              </td>
              <td class="px-6 py-4 text-sm text-gray-500 font-mono">{site.domain}</td>
              <td class="px-6 py-4">
                <span
                  :if={site.dns_verified}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"
                >
                  Verified
                </span>
                <span
                  :if={!site.dns_verified}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"
                >
                  Pending
                </span>
              </td>
              <td class="px-6 py-4">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(site.gdpr_mode == "on",
                    do: "bg-blue-100 text-blue-800",
                    else: "bg-gray-100 text-gray-600"
                  )
                ]}>
                  {site.gdpr_mode}
                </span>
              </td>
              <td class="px-6 py-4">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(site.active,
                    do: "bg-green-100 text-green-800",
                    else: "bg-gray-100 text-gray-600"
                  )
                ]}>
                  {if site.active, do: "Active", else: "Inactive"}
                </span>
              </td>
              <td class="px-6 py-4 text-right">
                <button
                  phx-click="register_domain"
                  phx-value-domain={site.domain}
                  class="text-green-600 hover:text-green-800 text-sm mr-4"
                >
                  Register Domain
                </button>
                <.link
                  navigate={~p"/dashboard/sites/#{site.id}/settings"}
                  class="text-indigo-600 hover:text-indigo-800 text-sm mr-4"
                >
                  Edit
                </.link>
                <button
                  phx-click="delete_site"
                  phx-value-id={site.id}
                  data-confirm={"Are you sure you want to delete #{site.name}? This cannot be undone."}
                  class="text-red-600 hover:text-red-800 text-sm"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
