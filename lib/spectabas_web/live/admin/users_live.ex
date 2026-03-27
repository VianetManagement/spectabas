defmodule SpectabasWeb.Admin.UsersLive do
  use SpectabasWeb, :live_view

  alias Spectabas.Accounts

  @roles ~w(superadmin admin analyst viewer)

  @impl true
  def mount(_params, _session, socket) do
    users = Accounts.list_users()
    pending = Accounts.list_pending_invitations()

    {:ok,
     socket
     |> assign(:page_title, "Manage Users")
     |> assign(:users, users)
     |> assign(:pending_invitations, pending)
     |> assign(:roles, @roles)
     |> assign(:show_invite, false)
     |> assign(:invite_email, "")
     |> assign(:invite_role, "analyst")
     |> assign(:invite_error, nil)}
  end

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

    case Accounts.invite_user(admin, email, role) do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invitation sent to #{email}.")
         |> assign(:show_invite, false)
         |> assign(:invite_email, "")
         |> assign(:invite_role, "analyst")
         |> assign(:invite_error, nil)
         |> assign(:pending_invitations, Accounts.list_pending_invitations())}

      {:error, reason} ->
        {:noreply, assign(socket, :invite_error, inspect(reason))}
    end
  end

  def handle_event("change_role", %{"user_id" => user_id, "role" => role}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(user_id)

    case Accounts.update_user_role(admin, user, role) do
      {:ok, _user} ->
        users = Accounts.list_users()
        {:noreply, socket |> put_flash(:info, "Role updated.") |> assign(:users, users)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update role: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_user", %{"id" => user_id}, socket) do
    admin = socket.assigns.current_scope.user
    user = Accounts.get_user!(user_id)

    case Accounts.delete_user(admin, user) do
      {:ok, _} ->
        users = Accounts.list_users()
        {:noreply, socket |> put_flash(:info, "User deleted.") |> assign(:users, users)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete user: #{inspect(reason)}")}
    end
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
          <h1 class="text-2xl font-bold text-gray-900 mt-2">Users</h1>
        </div>
        <button
          phx-click="toggle_invite"
          class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
        >
          {if @show_invite, do: "Cancel", else: "Invite User"}
        </button>
      </div>

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

      <div class="bg-white rounded-lg shadow overflow-hidden">
        <table class="min-w-full divide-y divide-gray-200">
          <thead class="bg-gray-50">
            <tr>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                User
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Role
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                2FA
              </th>
              <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Last Sign In
              </th>
              <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
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
                <form phx-change="change_role" phx-submit="change_role">
                  <input type="hidden" name="user_id" value={user.id} />
                  <select
                    name="role"
                    class={[
                      "text-xs font-medium rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 px-3 py-2.5",
                      role_color(to_string(user.role))
                    ]}
                  >
                    <option :for={r <- @roles} value={r} selected={to_string(user.role) == r}>
                      {String.capitalize(r)}
                    </option>
                  </select>
                </form>
              </td>
              <td class="px-6 py-4">
                <span
                  :if={user.totp_enabled}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"
                >
                  Enabled
                </span>
                <span
                  :if={!user.totp_enabled}
                  class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-600"
                >
                  Off
                </span>
              </td>
              <td class="px-6 py-4 text-sm text-gray-500">
                {if user.last_sign_in_at,
                  do: Calendar.strftime(user.last_sign_in_at, "%Y-%m-%d %H:%M"),
                  else: "Never"}
              </td>
              <td class="px-6 py-4 text-right">
                <button
                  :if={user.id != @current_scope.user.id}
                  phx-click="delete_user"
                  phx-value-id={user.id}
                  data-confirm={"Are you sure you want to delete #{user.email}?"}
                  class="text-red-600 hover:text-red-800 text-sm"
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
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Email</th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">Role</th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Invited
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase">
                  Status
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
                <td class="px-6 py-4">
                  <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800">
                    Invited
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp role_color("superadmin"), do: "bg-red-50 text-red-700"
  defp role_color("admin"), do: "bg-orange-50 text-orange-700"
  defp role_color("analyst"), do: "bg-blue-50 text-blue-700"
  defp role_color("viewer"), do: "bg-gray-50 text-gray-700"
  defp role_color(_), do: "bg-gray-50 text-gray-700"
end
