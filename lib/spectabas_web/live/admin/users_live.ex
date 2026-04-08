defmodule SpectabasWeb.Admin.UsersLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites}

  @all_roles ~w(superadmin admin analyst viewer)

  @timezones [
    "America/New_York",
    "America/Chicago",
    "America/Denver",
    "America/Los_Angeles",
    "America/Phoenix",
    "America/Anchorage",
    "Pacific/Honolulu",
    "UTC",
    "Europe/London",
    "Europe/Paris",
    "Europe/Berlin",
    "Asia/Tokyo",
    "Asia/Shanghai",
    "Australia/Sydney"
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    users = Accounts.list_users(user)
    pending = Accounts.list_pending_invitations(user)

    all_sites = Accounts.accessible_sites(user)

    {:ok,
     socket
     |> assign(:page_title, "Manage Users")
     |> assign(:users, users)
     |> assign(:pending_invitations, pending)
     |> assign(:roles, @all_roles)
     |> assign(:timezones, @timezones)
     |> assign(:all_sites, all_sites)
     |> assign(:show_invite, false)
     |> assign(:invite_email, "")
     |> assign(:invite_role, "analyst")
     |> assign(:invite_error, nil)
     |> assign(:editing_user, nil)
     |> assign(:edit_form, %{})
     |> assign(:edit_site_ids, MapSet.new())}
  end

  # -- Invite events --

  @impl true
  def handle_event("toggle_invite", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_invite, !socket.assigns.show_invite)
     |> assign(:invite_error, nil)}
  end

  def handle_event("update_invite", params, socket) do
    {:noreply,
     socket
     |> assign(:invite_email, Map.get(params, "email", socket.assigns.invite_email))
     |> assign(:invite_role, Map.get(params, "role", socket.assigns.invite_role))}
  end

  def handle_event("send_invite", _params, socket) do
    admin = socket.assigns.current_scope.user
    email = String.trim(socket.assigns.invite_email)
    role = socket.assigns.invite_role
    account_id = admin.account_id

    if is_nil(account_id) do
      {:noreply,
       assign(
         socket,
         :invite_error,
         "Platform admins must invite users from Platform > Account Detail page."
       )}
    else
      case Accounts.invite_user(admin, email, role, account_id) do
        {:ok, _invitation} ->
          {:noreply,
           socket
           |> put_flash(:info, "Invitation sent to #{email}.")
           |> assign(:show_invite, false)
           |> assign(:invite_email, "")
           |> assign(:invite_role, "analyst")
           |> assign(:invite_error, nil)
           |> assign(:pending_invitations, Accounts.list_pending_invitations(admin))}

        {:error, reason} ->
          {:noreply, assign(socket, :invite_error, inspect(reason))}
      end
    end
  end

  def handle_event("resend_invite", %{"id" => id}, socket) do
    admin = socket.assigns.current_scope.user
    invitation = Spectabas.Repo.get!(Spectabas.Accounts.Invitation, id)

    if admin.role != :platform_admin and invitation.account_id != admin.account_id do
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    else
      case Accounts.resend_invitation(admin, invitation) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Invitation resent to #{invitation.email}.")
           |> assign(:pending_invitations, Accounts.list_pending_invitations(admin))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to resend: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("delete_invite", %{"id" => id}, socket) do
    admin = socket.assigns.current_scope.user
    invitation = Spectabas.Repo.get!(Spectabas.Accounts.Invitation, id)

    if admin.role != :platform_admin and invitation.account_id != admin.account_id do
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    else
      case Accounts.delete_invitation(invitation) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Invitation for #{invitation.email} revoked.")
           |> assign(
             :pending_invitations,
             Accounts.list_pending_invitations(socket.assigns.current_scope.user)
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to revoke invitation.")}
      end
    end
  end

  # -- Edit user events --

  def handle_event("edit_user", %{"id" => user_id}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(user_id)

    # Account ownership check (platform_admin can edit anyone)
    if admin.role != :platform_admin and user.account_id != admin.account_id do
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    else
      perms = Accounts.list_user_permissions(user)
      site_ids = Enum.map(perms, & &1.site_id) |> MapSet.new()

      {:noreply,
       socket
       |> assign(:editing_user, user)
       |> assign(:edit_form, %{
         "display_name" => user.display_name || "",
         "role" => to_string(user.role),
         "timezone" => user.timezone || "America/New_York",
         "force_2fa" => user.force_2fa
       })
       |> assign(:edit_site_ids, site_ids)}
    end
  end

  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, :editing_user, nil)}
  end

  def handle_event("update_edit_form", params, socket) do
    form = socket.assigns.edit_form

    form =
      form
      |> maybe_update(params, "display_name")
      |> maybe_update(params, "role")
      |> maybe_update(params, "timezone")
      |> then(fn f ->
        if Map.has_key?(params, "force_2fa"),
          do: Map.put(f, "force_2fa", params["force_2fa"] == "true"),
          else: f
      end)

    {:noreply, assign(socket, :edit_form, form)}
  end

  def handle_event("save_user", _params, socket) do
    admin = socket.assigns.current_scope.user
    user = socket.assigns.editing_user
    form = socket.assigns.edit_form

    attrs = %{
      display_name: form["display_name"],
      role: String.to_existing_atom(form["role"]),
      timezone: form["timezone"],
      force_2fa: form["force_2fa"] || false
    }

    case user |> Accounts.User.profile_changeset(attrs) |> Spectabas.Repo.update() do
      {:ok, updated_user} ->
        # Sync site permissions for analyst/viewer
        if form["role"] in ["analyst", "viewer"] do
          sync_site_permissions(admin, updated_user, socket.assigns.edit_site_ids)
        end

        {:noreply,
         socket
         |> put_flash(:info, "User updated.")
         |> assign(:users, Accounts.list_users(socket.assigns.current_scope.user))
         |> assign(:editing_user, nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update user.")}
    end
  end

  def handle_event("toggle_site_access", %{"site-id" => sid}, socket) do
    site_id = String.to_integer(sid)
    current = socket.assigns.edit_site_ids

    new_ids =
      if MapSet.member?(current, site_id),
        do: MapSet.delete(current, site_id),
        else: MapSet.put(current, site_id)

    {:noreply, assign(socket, :edit_site_ids, new_ids)}
  end

  def handle_event("send_login_link", %{"id" => user_id}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(user_id)

    if admin.role != :platform_admin and user.account_id != admin.account_id do
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    else
      Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
      {:noreply, put_flash(socket, :info, "Login link sent to #{user.email}")}
    end
  end

  def handle_event("force_logout", %{"id" => user_id}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(user_id)

    if admin.role != :platform_admin and user.account_id != admin.account_id do
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    else
      {count, tokens} = Accounts.delete_all_user_sessions(user)
      SpectabasWeb.UserAuth.disconnect_sessions(tokens)

      Spectabas.Audit.log("user.force_logout", %{
        user_id: user.id,
        email: user.email,
        admin_id: admin.id,
        admin_email: admin.email,
        sessions_terminated: count
      })

      {:noreply,
       put_flash(socket, :info, "#{user.email} has been logged out of #{count} session(s).")}
    end
  end

  def handle_event("delete_user", %{"id" => user_id}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(user_id)

    # Account ownership check
    if admin.role != :platform_admin and user.account_id != admin.account_id do
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    else
      case Accounts.delete_user(admin, user) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "User deleted.")
           |> assign(:users, Accounts.list_users(socket.assigns.current_scope.user))
           |> assign(:editing_user, nil)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to delete user: #{inspect(reason)}")}
      end
    end
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <div>
          <.link navigate={~p"/admin"} class="text-sm text-indigo-600 hover:text-indigo-800">
            &larr; Admin Dashboard
          </.link>
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Users</h1>
        </div>
        <button
          phx-click="toggle_invite"
          class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
        >
          {if @show_invite, do: "Cancel", else: "Invite User"}
        </button>
      </div>

      <%!-- Invite Form --%>
      <div :if={@show_invite} class="bg-white rounded-lg shadow p-6 mb-8">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Invite User</h2>
        <form phx-change="update_invite" phx-submit="send_invite" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div class="md:col-span-2">
              <label class="block text-sm font-medium text-gray-700">Email</label>
              <input
                type="email"
                name="email"
                value={@invite_email}
                required
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                placeholder="user@example.com"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Role</label>
              <select
                name="role"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
              >
                <option :for={r <- @roles} value={r} selected={@invite_role == r}>
                  {String.capitalize(r)}
                </option>
              </select>
            </div>
          </div>
          <p :if={@invite_error} class="text-sm text-red-600">{@invite_error}</p>
          <div class="flex justify-end">
            <button
              type="submit"
              class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
            >
              Send Invitation
            </button>
          </div>
        </form>
      </div>

      <%!-- Edit User Panel --%>
      <div :if={@editing_user} class="bg-white rounded-lg shadow p-6 mb-8">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-gray-900">
            Edit: {@editing_user.email}
          </h2>
          <button phx-click="close_edit" class="text-sm text-gray-500 hover:text-gray-700">
            Close
          </button>
        </div>

        <form phx-change="update_edit_form" phx-submit="save_user" class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-gray-700">Display Name</label>
              <input
                type="text"
                name="display_name"
                value={@edit_form["display_name"]}
                placeholder="Optional display name"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Role</label>
              <select
                name="role"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
              >
                <option :for={r <- @roles} value={r} selected={@edit_form["role"] == r}>
                  {String.capitalize(r)}
                </option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium text-gray-700">Timezone</label>
              <select
                name="timezone"
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
              >
                <option
                  :for={tz <- @timezones}
                  value={tz}
                  selected={@edit_form["timezone"] == tz}
                >
                  {tz}
                </option>
              </select>
            </div>
            <div class="flex items-center pt-6">
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="hidden"
                  name="force_2fa"
                  value="false"
                />
                <input
                  type="checkbox"
                  name="force_2fa"
                  value="true"
                  checked={@edit_form["force_2fa"]}
                  class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                />
                <span class="text-sm font-medium text-gray-700">Require 2FA</span>
              </label>
            </div>
          </div>

          <%!-- Site Access (only for analyst/viewer) --%>
          <div :if={@edit_form["role"] in ["analyst", "viewer"]}>
            <label class="block text-sm font-medium text-gray-700 mb-2">Site Access</label>
            <div class="flex flex-wrap gap-2">
              <button
                :for={site <- @all_sites}
                type="button"
                phx-click="toggle_site_access"
                phx-value-site-id={site.id}
                class={[
                  "px-3 py-1.5 text-xs font-medium rounded-lg border transition-colors",
                  if(MapSet.member?(@edit_site_ids, site.id),
                    do: "bg-indigo-600 text-white border-indigo-600",
                    else: "bg-white text-gray-700 border-gray-300 hover:border-indigo-400"
                  )
                ]}
              >
                {site.name}
              </button>
            </div>
            <p class="text-xs text-gray-500 mt-1">
              Select which sites this user can access. No sites selected = no access.
            </p>
          </div>

          <div :if={@edit_form["role"] in ["superadmin", "admin"]}>
            <p class="text-xs text-gray-500">
              Superadmin and Admin roles have access to all sites automatically.
            </p>
          </div>

          <div class="flex justify-end gap-3 pt-2">
            <button
              type="button"
              phx-click="close_edit"
              class="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-4 py-2 text-sm font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700"
            >
              Save Changes
            </button>
          </div>
        </form>
      </div>

      <%!-- Role Guide --%>
      <div class="bg-gray-50 rounded-lg border border-gray-200 p-4 mb-6">
        <h3 class="text-sm font-semibold text-gray-700 mb-2">Role Permissions</h3>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 text-xs text-gray-600">
          <div>
            <span class="inline-block px-2 py-0.5 rounded bg-red-50 text-red-700 font-medium mb-1">
              Superadmin
            </span>
            <p>Full access. Manage users, sites, billing.</p>
          </div>
          <div>
            <span class="inline-block px-2 py-0.5 rounded bg-orange-50 text-orange-700 font-medium mb-1">
              Admin
            </span>
            <p>Manage sites and settings. All site access.</p>
          </div>
          <div>
            <span class="inline-block px-2 py-0.5 rounded bg-blue-50 text-blue-700 font-medium mb-1">
              Analyst
            </span>
            <p>View analytics for permitted sites only.</p>
          </div>
          <div>
            <span class="inline-block px-2 py-0.5 rounded bg-gray-100 text-gray-700 font-medium mb-1">
              Viewer
            </span>
            <p>Read-only dashboard for permitted sites only.</p>
          </div>
        </div>
      </div>

      <%!-- User Table --%>
      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">User</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Role</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">2FA</th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Site Access
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                Last Sign In
              </th>
              <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                Actions
              </th>
            </tr>
          </thead>
          <tbody class="bg-white divide-y divide-gray-200">
            <tr :for={user <- @users} class="hover:bg-gray-50">
              <td class="px-6 py-4">
                <div class="text-sm font-medium text-gray-900">
                  {user.display_name || user.email}
                </div>
                <div :if={user.display_name} class="text-sm text-gray-500">{user.email}</div>
              </td>
              <td class="px-6 py-4">
                <span class={"text-xs font-medium rounded-lg px-2 py-1 #{role_color(to_string(user.role))}"}>
                  {String.capitalize(to_string(user.role))}
                </span>
              </td>
              <td class="px-6 py-4">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                  if(user.totp_enabled,
                    do: "bg-green-100 text-green-800",
                    else: "bg-gray-100 text-gray-600"
                  )
                ]}>
                  {if user.totp_enabled, do: "Enabled", else: "Off"}
                </span>
                <span
                  :if={user.force_2fa}
                  class="ml-1 inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-medium bg-amber-100 text-amber-800"
                >
                  Required
                </span>
              </td>
              <td class="px-6 py-4 text-xs text-gray-500">
                {if to_string(user.role) in ["superadmin", "admin"],
                  do: "All sites",
                  else: "Per-site"}
              </td>
              <td class="px-6 py-4 text-sm text-gray-500">
                {if user.last_sign_in_at,
                  do: Calendar.strftime(user.last_sign_in_at, "%Y-%m-%d %H:%M"),
                  else: "Never"}
              </td>
              <td class="px-6 py-4 text-right space-x-3">
                <button
                  :if={user.id != @current_scope.user.id}
                  phx-click="edit_user"
                  phx-value-id={user.id}
                  class="text-indigo-600 hover:text-indigo-800 text-sm font-medium"
                >
                  Edit
                </button>
                <button
                  :if={user.id != @current_scope.user.id}
                  phx-click="send_login_link"
                  phx-value-id={user.id}
                  data-confirm={"Send a login link email to #{user.email}?"}
                  class="text-amber-600 hover:text-amber-800 text-sm font-medium"
                >
                  Send Login Link
                </button>
                <button
                  :if={user.id != @current_scope.user.id}
                  phx-click="force_logout"
                  phx-value-id={user.id}
                  data-confirm={"Force logout #{user.email} from all sessions?"}
                  class="text-orange-600 hover:text-orange-800 text-sm font-medium"
                >
                  Force Logout
                </button>
                <button
                  :if={user.id != @current_scope.user.id}
                  phx-click="delete_user"
                  phx-value-id={user.id}
                  data-confirm={"Are you sure you want to delete #{user.email}?"}
                  class="text-red-600 hover:text-red-800 text-sm font-medium"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Pending Invitations --%>
      <div :if={@pending_invitations != []} class="mt-8">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Pending Invitations</h2>
        <div class="bg-white rounded-lg shadow overflow-hidden">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-yellow-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Email
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Role
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Invited
                </th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-200">
              <tr :for={inv <- @pending_invitations} class="hover:bg-gray-50">
                <td class="px-6 py-4 text-sm text-gray-900">{inv.email}</td>
                <td class="px-6 py-4">
                  <span class={"text-xs font-medium rounded-lg px-2 py-1 #{role_color(to_string(inv.role))}"}>
                    {String.capitalize(to_string(inv.role))}
                  </span>
                </td>
                <td class="px-6 py-4 text-sm text-gray-500">
                  {Calendar.strftime(inv.inserted_at, "%Y-%m-%d %H:%M")}
                </td>
                <td class="px-6 py-4 text-right space-x-3">
                  <button
                    phx-click="resend_invite"
                    phx-value-id={inv.id}
                    class="text-indigo-600 hover:text-indigo-800 text-sm font-medium"
                  >
                    Resend
                  </button>
                  <button
                    phx-click="delete_invite"
                    phx-value-id={inv.id}
                    data-confirm={"Revoke invitation for #{inv.email}?"}
                    class="text-red-500 hover:text-red-700 text-sm font-medium"
                  >
                    Revoke
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # -- Private --

  defp sync_site_permissions(admin, user, desired_site_ids) do
    current_perms = Accounts.list_user_permissions(user)
    current_ids = Enum.map(current_perms, & &1.site_id) |> MapSet.new()

    # Grant new — only for sites the admin can access
    to_grant = MapSet.difference(desired_site_ids, current_ids)

    Enum.each(to_grant, fn site_id ->
      site = Sites.get_site!(site_id)

      if Accounts.can_access_site?(admin, site) do
        Accounts.grant_permission(admin, user, site, user.role)
      end
    end)

    # Revoke removed — only for sites the admin can access
    to_revoke = MapSet.difference(current_ids, desired_site_ids)

    Enum.each(to_revoke, fn site_id ->
      site = Sites.get_site!(site_id)

      if Accounts.can_access_site?(admin, site) do
        Accounts.revoke_permission(admin, user, site)
      end
    end)
  end

  defp maybe_update(form, params, key) do
    if Map.has_key?(params, key), do: Map.put(form, key, params[key]), else: form
  end

  defp role_color("superadmin"), do: "bg-red-50 text-red-700"
  defp role_color("admin"), do: "bg-orange-50 text-orange-700"
  defp role_color("analyst"), do: "bg-blue-50 text-blue-700"
  defp role_color("viewer"), do: "bg-gray-50 text-gray-700"
  defp role_color(_), do: "bg-gray-50 text-gray-700"
end
