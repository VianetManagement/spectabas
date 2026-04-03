defmodule SpectabasWeb.Platform.AccountsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Repo}
  alias Spectabas.Accounts.Account
  alias Spectabas.Sites.Site
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Manage Accounts")
     |> assign(:show_form, false)
     |> assign(:form, to_form(Account.changeset(%Account{}, %{})))
     |> assign(:invite_account_id, nil)
     |> assign(:invite_email, "")
     |> assign(:invite_error, nil)
     |> load_accounts()}
  end

  defp load_accounts(socket) do
    accounts = Accounts.list_accounts()

    account_stats =
      Enum.map(accounts, fn acct ->
        sites = Repo.aggregate(from(s in Site, where: s.account_id == ^acct.id), :count)
        users = Repo.aggregate(from(u in Accounts.User, where: u.account_id == ^acct.id), :count)
        %{account: acct, sites: sites, users: users}
      end)

    assign(socket, :account_stats, account_stats)
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, !socket.assigns.show_form)}
  end

  def handle_event("validate_account", %{"account" => params}, socket) do
    changeset =
      %Account{}
      |> Account.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create_account", %{"account" => params}, socket) do
    admin = socket.assigns.current_scope.user

    case Accounts.create_account(admin, params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created.")
         |> assign(:show_form, false)
         |> assign(:form, to_form(Account.changeset(%Account{}, %{})))
         |> load_accounts()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("show_invite", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:invite_account_id, String.to_integer(id))
     |> assign(:invite_email, "")
     |> assign(:invite_error, nil)}
  end

  def handle_event("cancel_invite", _params, socket) do
    {:noreply, assign(socket, :invite_account_id, nil)}
  end

  def handle_event("update_invite_email", %{"email" => email}, socket) do
    {:noreply, assign(socket, :invite_email, email)}
  end

  def handle_event("send_invite", _params, socket) do
    admin = socket.assigns.current_scope.user
    email = String.trim(socket.assigns.invite_email)
    account_id = socket.assigns.invite_account_id

    case Accounts.invite_user(admin, email, :superadmin, account_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Superadmin invitation sent to #{email}.")
         |> assign(:invite_account_id, nil)
         |> assign(:invite_email, "")}

      {:error, reason} ->
        {:noreply, assign(socket, :invite_error, inspect(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto py-8 px-4">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold text-gray-900">Accounts</h1>
        <button
          phx-click="toggle_form"
          class="px-4 py-2 bg-purple-600 text-white text-sm rounded-lg hover:bg-purple-700"
        >
          {if @show_form, do: "Cancel", else: "New Account"}
        </button>
      </div>

      <%= if @show_form do %>
        <div class="bg-white border rounded-lg p-6 mb-6">
          <h2 class="text-lg font-semibold mb-4">Create Account</h2>
          <.form
            for={@form}
            phx-change="validate_account"
            phx-submit="create_account"
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
                  placeholder="Acme Corp"
                />
                <%= if @form[:name].errors != [] do %>
                  <p class="text-red-500 text-xs mt-1">{elem(hd(@form[:name].errors), 0)}</p>
                <% end %>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Slug</label>
                <input
                  type="text"
                  name="account[slug]"
                  value={@form[:slug].value}
                  class="w-full border rounded-lg px-3 py-2 text-sm"
                  placeholder="acme"
                />
                <%= if @form[:slug].errors != [] do %>
                  <p class="text-red-500 text-xs mt-1">{elem(hd(@form[:slug].errors), 0)}</p>
                <% end %>
              </div>
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">Site Limit</label>
                <input
                  type="number"
                  name="account[site_limit]"
                  value={@form[:site_limit].value || 10}
                  class="w-full border rounded-lg px-3 py-2 text-sm"
                />
              </div>
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-indigo-600 text-white text-sm rounded-lg hover:bg-indigo-700"
            >
              Create Account
            </button>
          </.form>
        </div>
      <% end %>

      <div class="bg-white border rounded-lg overflow-hidden">
        <table class="w-full text-sm">
          <thead class="bg-gray-50 border-b">
            <tr>
              <th class="text-left px-4 py-3 font-medium text-gray-700">Account</th>
              <th class="text-left px-4 py-3 font-medium text-gray-700">Slug</th>
              <th class="text-right px-4 py-3 font-medium text-gray-700">Sites</th>
              <th class="text-right px-4 py-3 font-medium text-gray-700">Limit</th>
              <th class="text-right px-4 py-3 font-medium text-gray-700">Users</th>
              <th class="text-center px-4 py-3 font-medium text-gray-700">Status</th>
              <th class="text-right px-4 py-3 font-medium text-gray-700">Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for stat <- @account_stats do %>
              <tr class="border-b hover:bg-gray-50">
                <td class="px-4 py-3">
                  <a
                    href={"/platform/accounts/#{stat.account.id}"}
                    class="text-indigo-600 hover:text-indigo-800 font-medium"
                  >
                    {stat.account.name}
                  </a>
                </td>
                <td class="px-4 py-3 text-gray-500 font-mono text-xs">{stat.account.slug}</td>
                <td class="text-right px-4 py-3">{stat.sites}</td>
                <td class="text-right px-4 py-3 text-gray-500">{stat.account.site_limit}</td>
                <td class="text-right px-4 py-3">{stat.users}</td>
                <td class="text-center px-4 py-3">
                  <%= if stat.account.active do %>
                    <span class="inline-block px-2 py-0.5 text-xs font-medium rounded-full bg-green-100 text-green-700">
                      Active
                    </span>
                  <% else %>
                    <span class="inline-block px-2 py-0.5 text-xs font-medium rounded-full bg-red-100 text-red-700">
                      Inactive
                    </span>
                  <% end %>
                </td>
                <td class="text-right px-4 py-3">
                  <button
                    phx-click="show_invite"
                    phx-value-id={stat.account.id}
                    class="text-xs text-purple-600 hover:text-purple-800 font-medium"
                  >
                    Invite Superadmin
                  </button>
                </td>
              </tr>

              <%= if @invite_account_id == stat.account.id do %>
                <tr class="bg-purple-50">
                  <td colspan="7" class="px-4 py-3">
                    <div class="flex items-center gap-3">
                      <span class="text-sm text-purple-700 font-medium">
                        Invite superadmin to {stat.account.name}:
                      </span>
                      <input
                        type="email"
                        phx-keyup="update_invite_email"
                        value={@invite_email}
                        class="border rounded px-3 py-1.5 text-sm w-64"
                        placeholder="email@example.com"
                      />
                      <button
                        phx-click="send_invite"
                        class="px-3 py-1.5 bg-purple-600 text-white text-sm rounded hover:bg-purple-700"
                      >
                        Send Invitation
                      </button>
                      <button
                        phx-click="cancel_invite"
                        class="text-sm text-gray-500 hover:text-gray-700"
                      >
                        Cancel
                      </button>
                      <%= if @invite_error do %>
                        <span class="text-sm text-red-600">{@invite_error}</span>
                      <% end %>
                    </div>
                  </td>
                </tr>
              <% end %>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
