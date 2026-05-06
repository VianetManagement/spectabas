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

    # Platform admins create sites on behalf of any account, so they need an
    # account selector in the form. Other roles are scoped to their own.
    accounts =
      if user.role == :platform_admin do
        Spectabas.Accounts.list_accounts()
      else
        []
      end

    {:ok,
     socket
     |> assign(:page_title, "Manage Sites")
     |> assign(:sites, sites)
     |> assign(:account, account)
     |> assign(:accounts, accounts)
     |> assign(:show_form, false)
     |> assign(:moving_site_id, nil)
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

    # Lock non-platform-admins to their own account; platform admins must
    # choose explicitly via the form. Previously we silently defaulted a
    # platform admin's site creation to the first account in the table —
    # which produced cross-account misassignment when an admin in account
    # A created sites intended for account B (v6.10.3 fix).
    account_id =
      cond do
        user.account_id ->
          user.account_id

        user.role == :platform_admin ->
          case params["account_id"] do
            id when is_binary(id) and id != "" -> String.to_integer(id)
            _ -> nil
          end

        true ->
          nil
      end

    cond do
      is_nil(account_id) ->
        msg =
          if user.role == :platform_admin,
            do: "Pick an account for the new site.",
            else: "No account found. Create an account first."

        {:noreply, put_flash(socket, :error, msg)}

      not Spectabas.Accounts.can_create_site?(user) ->
        {:noreply, put_flash(socket, :error, "Site limit reached for this account.")}

      true ->
        params = Map.put(params, "account_id", account_id)

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

  def handle_event("open_move", %{"id" => site_id}, socket) do
    user = socket.assigns.current_scope.user

    if user.role != :platform_admin do
      {:noreply,
       put_flash(socket, :error, "Only platform admins can move sites between accounts.")}
    else
      {:noreply, assign(socket, :moving_site_id, site_id)}
    end
  end

  def handle_event("cancel_move", _params, socket) do
    {:noreply, assign(socket, :moving_site_id, nil)}
  end

  def handle_event("move_site", %{"site_id" => site_id, "account_id" => target_id}, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    target_account_id =
      case target_id do
        id when is_binary(id) and id != "" -> String.to_integer(id)
        _ -> nil
      end

    cond do
      user.role != :platform_admin ->
        {:noreply,
         put_flash(socket, :error, "Only platform admins can move sites between accounts.")}

      is_nil(target_account_id) ->
        {:noreply, put_flash(socket, :error, "Pick a target account.")}

      true ->
        case Sites.move_to_account(site, user, target_account_id) do
          {:ok, _moved} ->
            target = Spectabas.Accounts.get_account!(target_account_id)
            sites = Spectabas.Accounts.accessible_sites(user)

            {:noreply,
             socket
             |> put_flash(:info, "Moved \"#{site.name}\" to account \"#{target.name}\".")
             |> assign(:sites, sites)
             |> assign(:moving_site_id, nil)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Move failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("delete_site", %{"id" => site_id}, socket) do
    admin = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if not Spectabas.Accounts.can_access_site?(admin, site) do
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    else
      case Sites.delete_site(admin, site) do
        {:ok, _} ->
          sites = Spectabas.Accounts.accessible_sites(admin)
          {:noreply, socket |> put_flash(:info, "Site deleted.") |> assign(:sites, sites)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to delete site: #{inspect(reason)}")}
      end
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
          <div :if={@accounts != []} class="rounded-lg bg-amber-50 border border-amber-200 p-3">
            <label class="block text-sm font-medium text-amber-900 mb-1">
              Account <span class="text-amber-700">(platform admin)</span>
            </label>
            <select
              name="site[account_id]"
              required
              class="mt-1 block w-full rounded-lg border-amber-300 shadow-sm focus:border-amber-500 focus:ring-amber-500 sm:text-sm px-3 py-2.5 bg-white"
            >
              <option value="">— Pick an account —</option>
              <option :for={a <- @accounts} value={a.id}>
                {a.name} ({a.slug}, id={a.id})
              </option>
            </select>
            <p class="mt-1 text-xs text-amber-800">
              The site will be assigned to this account and only its users will see it. Verify before submitting.
            </p>
          </div>
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
              <th
                :if={@accounts != []}
                class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider"
              >
                Account
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
              <td colspan="7" class="px-6 py-8 text-center text-gray-500">No sites yet.</td>
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
              <td :if={@accounts != []} class="px-6 py-4 text-sm text-gray-700">
                <%!-- Inline move form when this row is being moved --%>
                <%= if to_string(@moving_site_id) == to_string(site.id) do %>
                  <form phx-submit="move_site" class="flex items-center gap-2">
                    <input type="hidden" name="site_id" value={site.id} />
                    <select
                      name="account_id"
                      class="rounded border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 text-xs px-2 py-1"
                    >
                      <option value="">Pick account…</option>
                      <option
                        :for={a <- @accounts}
                        value={a.id}
                        selected={a.id == site.account_id}
                      >
                        {a.name} ({a.slug}, id={a.id})
                      </option>
                    </select>
                    <button
                      type="submit"
                      data-confirm={"Move #{site.name} to a different account? Visitors, goals, conversions, and integrations all follow the site. ClickHouse data is unchanged."}
                      class="inline-flex items-center px-2 py-1 text-xs font-medium rounded text-white bg-amber-600 hover:bg-amber-700"
                    >
                      Move
                    </button>
                    <button
                      type="button"
                      phx-click="cancel_move"
                      class="text-xs text-gray-500 hover:text-gray-700"
                    >
                      Cancel
                    </button>
                  </form>
                <% else %>
                  <% acct = Enum.find(@accounts, &(&1.id == site.account_id)) %>
                  <div class="flex items-center gap-2">
                    <span class="text-xs">
                      <%= if acct do %>
                        {acct.name}
                        <span class="text-gray-400 font-mono">({acct.slug})</span>
                      <% else %>
                        <span class="text-red-600">unknown (id={site.account_id})</span>
                      <% end %>
                    </span>
                    <button
                      phx-click="open_move"
                      phx-value-id={site.id}
                      class="text-xs text-amber-700 hover:text-amber-900 underline"
                    >
                      Move
                    </button>
                  </div>
                <% end %>
              </td>
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
