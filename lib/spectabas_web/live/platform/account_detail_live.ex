defmodule SpectabasWeb.Platform.AccountDetailLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Repo}
  alias Spectabas.Accounts.{Account, Invitation}
  alias Spectabas.Sites.Site
  import Ecto.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    account = Accounts.get_account!(id)

    users =
      Repo.all(
        from(u in Accounts.User, where: u.account_id == ^account.id, order_by: [asc: u.email])
      )

    sites = Repo.all(from(s in Site, where: s.account_id == ^account.id, order_by: [asc: s.name]))

    pending =
      Repo.all(
        from(i in Invitation,
          where: i.account_id == ^account.id and is_nil(i.accepted_at),
          order_by: [desc: i.inserted_at]
        )
      )

    {:ok,
     socket
     |> assign(:page_title, "Account: #{account.name}")
     |> assign(:account, account)
     |> assign(:users, users)
     |> assign(:sites, sites)
     |> assign(:pending_invitations, pending)
     |> assign(:editing, false)
     |> assign(:form, to_form(Account.changeset(account, %{})))
     |> assign(:invite_email, "")
     |> assign(:invite_role, "superadmin")
     |> assign(:invite_error, nil)
     |> assign(:show_invite, false)}
  end

  @impl true
  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, :editing, !socket.assigns.editing)}
  end

  def handle_event("validate_account", %{"account" => params}, socket) do
    changeset =
      socket.assigns.account
      |> Account.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("update_account", %{"account" => params}, socket) do
    case Accounts.update_account(socket.assigns.account, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated.")
         |> assign(:account, account)
         |> assign(:editing, false)
         |> assign(:form, to_form(Account.changeset(account, %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

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

  def handle_event("send_invite", params, socket) do
    admin = socket.assigns.current_scope.user
    email = String.trim(params["email"] || "")
    role = params["role"] || "superadmin"
    account_id = socket.assigns.account.id

    case Accounts.invite_user(admin, email, role, account_id) do
      {:ok, _} ->
        pending =
          Repo.all(
            from(i in Invitation,
              where: i.account_id == ^account_id and is_nil(i.accepted_at),
              order_by: [desc: i.inserted_at]
            )
          )

        {:noreply,
         socket
         |> put_flash(:info, "Invitation sent to #{email}.")
         |> assign(:show_invite, false)
         |> assign(:invite_email, "")
         |> assign(:invite_error, nil)
         |> assign(:pending_invitations, pending)}

      {:error, reason} ->
        {:noreply, assign(socket, :invite_error, inspect(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto py-8 px-4">
      <div class="flex items-center gap-3 mb-6">
        <a href="/platform/accounts" class="text-gray-400 hover:text-gray-600">&larr;</a>
        <h1 class="text-2xl font-bold text-gray-900">{@account.name}</h1>
        <span class="text-sm text-gray-500 font-mono">{@account.slug}</span>
        <%= if @account.active do %>
          <span class="inline-block px-2 py-0.5 text-xs font-medium rounded-full bg-green-100 text-green-700">
            Active
          </span>
        <% else %>
          <span class="inline-block px-2 py-0.5 text-xs font-medium rounded-full bg-red-100 text-red-700">
            Inactive
          </span>
        <% end %>
      </div>

      <%!-- Account settings --%>
      <div class="bg-white border rounded-lg p-6 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold">Account Settings</h2>
          <button phx-click="toggle_edit" class="text-sm text-indigo-600 hover:text-indigo-800">
            {if @editing, do: "Cancel", else: "Edit"}
          </button>
        </div>

        <%= if @editing do %>
          <.form
            for={@form}
            phx-change="validate_account"
            phx-submit="update_account"
            class="space-y-4"
          >
            <div class="grid grid-cols-3 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Name</label>
                <input
                  type="text"
                  name="account[name]"
                  value={@form[:name].value}
                  class="w-full border rounded-lg px-3 py-2 text-sm"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Slug</label>
                <input
                  type="text"
                  name="account[slug]"
                  value={@form[:slug].value}
                  class="w-full border rounded-lg px-3 py-2 text-sm"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Site Limit</label>
                <input
                  type="number"
                  name="account[site_limit]"
                  value={@form[:site_limit].value}
                  class="w-full border rounded-lg px-3 py-2 text-sm"
                />
              </div>
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-indigo-600 text-white text-sm rounded-lg hover:bg-indigo-700"
            >
              Save
            </button>
          </.form>
        <% else %>
          <div class="grid grid-cols-3 gap-4 text-sm">
            <div>
              <span class="text-gray-500">Site Limit:</span>
              <span class="font-medium ml-1">{@account.site_limit}</span>
            </div>
            <div>
              <span class="text-gray-500">Sites:</span>
              <span class="font-medium ml-1">{length(@sites)}</span>
            </div>
            <div>
              <span class="text-gray-500">Users:</span>
              <span class="font-medium ml-1">{length(@users)}</span>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Users --%>
      <div class="bg-white border rounded-lg p-6 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold">Users</h2>
          <button
            phx-click="toggle_invite"
            class="px-3 py-1.5 bg-purple-600 text-white text-xs rounded-lg hover:bg-purple-700"
          >
            {if @show_invite, do: "Cancel", else: "Invite User"}
          </button>
        </div>

        <%= if @show_invite do %>
          <div class="bg-purple-50 border border-purple-200 rounded-lg p-4 mb-4">
            <form phx-submit="send_invite" class="flex items-center gap-3">
              <input
                type="email"
                name="email"
                class="border rounded px-3 py-1.5 text-sm w-64"
                placeholder="email@example.com"
                required
                autofocus
              />
              <select name="role" class="border rounded px-3 py-1.5 text-sm">
                <option value="superadmin">Superadmin</option>
                <option value="admin">Admin</option>
                <option value="analyst">Analyst</option>
                <option value="viewer">Viewer</option>
              </select>
              <button
                type="submit"
                class="px-3 py-1.5 bg-purple-600 text-white text-sm rounded hover:bg-purple-700"
              >
                Send
              </button>
            </form>
            <%= if @invite_error do %>
              <p class="text-sm text-red-600 mt-2">{@invite_error}</p>
            <% end %>
          </div>
        <% end %>

        <table class="w-full text-sm">
          <thead class="border-b">
            <tr>
              <th class="text-left px-3 py-2 font-medium text-gray-700">Email</th>
              <th class="text-left px-3 py-2 font-medium text-gray-700">Name</th>
              <th class="text-left px-3 py-2 font-medium text-gray-700">Role</th>
            </tr>
          </thead>
          <tbody>
            <%= for user <- @users do %>
              <tr class="border-b">
                <td class="px-3 py-2">{user.email}</td>
                <td class="px-3 py-2 text-gray-500">{user.display_name || "—"}</td>
                <td class="px-3 py-2">
                  <span class={"inline-block px-2 py-0.5 text-xs font-medium rounded-full #{role_color(user.role)}"}>
                    {user.role}
                  </span>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <%= if @pending_invitations != [] do %>
          <div class="mt-4 pt-4 border-t">
            <h3 class="text-sm font-medium text-gray-700 mb-2">Pending Invitations</h3>
            <%= for inv <- @pending_invitations do %>
              <div class="flex items-center gap-2 text-sm text-gray-600 py-1">
                <span>{inv.email}</span>
                <span class="text-xs text-gray-400">({inv.role})</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Sites --%>
      <div class="bg-white border rounded-lg p-6">
        <h2 class="text-lg font-semibold mb-4">Sites</h2>
        <table class="w-full text-sm">
          <thead class="border-b">
            <tr>
              <th class="text-left px-3 py-2 font-medium text-gray-700">Name</th>
              <th class="text-left px-3 py-2 font-medium text-gray-700">Domain</th>
              <th class="text-center px-3 py-2 font-medium text-gray-700">Active</th>
            </tr>
          </thead>
          <tbody>
            <%= for site <- @sites do %>
              <tr class="border-b">
                <td class="px-3 py-2 font-medium">{site.name}</td>
                <td class="px-3 py-2 text-gray-500 font-mono text-xs">{site.domain}</td>
                <td class="text-center px-3 py-2">
                  <%= if site.active do %>
                    <span class="text-green-600">Yes</span>
                  <% else %>
                    <span class="text-red-600">No</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp role_color(:superadmin), do: "bg-red-100 text-red-700"
  defp role_color(:admin), do: "bg-orange-100 text-orange-700"
  defp role_color(:analyst), do: "bg-blue-100 text-blue-700"
  defp role_color(:viewer), do: "bg-gray-100 text-gray-600"
  defp role_color(_), do: "bg-gray-100 text-gray-600"
end
