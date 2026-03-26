defmodule SpectabasWeb.UserLive.Settings do
  use SpectabasWeb, :live_view

  on_mount {SpectabasWeb.UserAuth, :require_sudo_mode}

  alias Spectabas.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.link navigate={~p"/dashboard"} class="text-sm text-indigo-600 hover:text-indigo-800">
          &larr; Dashboard
        </.link>
        <h1 class="text-2xl font-bold text-gray-900 mt-2">Account Settings</h1>
        <p class="text-sm text-gray-500 mt-1">Manage your email and password</p>
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

      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Change Email</h2>
        <.form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
          class="space-y-4"
        >
          <div>
            <label for="email_form_email" class="block text-sm font-medium text-gray-700">
              Email
            </label>
            <input
              id="email_form_email"
              name={@email_form[:email].name}
              type="email"
              value={@email_form[:email].value}
              autocomplete="username"
              required
              class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
            />
            <p :if={@email_form[:email].errors != []} class="mt-1 text-sm text-red-600">
              {SpectabasWeb.CoreComponents.translate_error(hd(@email_form[:email].errors))}
            </p>
          </div>
          <button
            type="submit"
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-lg shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 transition"
          >
            Change Email
          </button>
        </.form>
      </div>

      <div class="bg-white rounded-lg shadow p-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Change Password</h2>
        <.form
          for={@password_form}
          id="password_form"
          action={~p"/users/update-password"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <input
            name={@password_form[:email].name}
            type="hidden"
            id="hidden_user_email"
            value={@current_email}
          />
          <div>
            <label for="password_form_password" class="block text-sm font-medium text-gray-700">
              New password
            </label>
            <input
              id="password_form_password"
              name={@password_form[:password].name}
              type="password"
              value={@password_form[:password].value}
              autocomplete="new-password"
              required
              class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
            />
            <p :if={@password_form[:password].errors != []} class="mt-1 text-sm text-red-600">
              {SpectabasWeb.CoreComponents.translate_error(hd(@password_form[:password].errors))}
            </p>
          </div>
          <div>
            <label
              for="password_form_password_confirmation"
              class="block text-sm font-medium text-gray-700"
            >
              Confirm new password
            </label>
            <input
              id="password_form_password_confirmation"
              name={@password_form[:password_confirmation].name}
              type="password"
              value={@password_form[:password_confirmation].value}
              autocomplete="new-password"
              class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
            />
            <p
              :if={@password_form[:password_confirmation].errors != []}
              class="mt-1 text-sm text-red-600"
            >
              {SpectabasWeb.CoreComponents.translate_error(
                hd(@password_form[:password_confirmation].errors)
              )}
            </p>
          </div>
          <button
            type="submit"
            class="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-lg shadow-sm text-white bg-indigo-600 hover:bg-indigo-700 transition"
          >
            Save Password
          </button>
        </.form>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:page_title, "Account Settings")
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
