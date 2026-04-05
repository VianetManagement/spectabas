defmodule SpectabasWeb.UserLive.Settings do
  use SpectabasWeb, :live_view

  on_mount {SpectabasWeb.UserAuth, :require_sudo_mode}

  alias Spectabas.{Accounts, APIKeys}
  alias Spectabas.Accounts.Webauthn

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="mb-8">
        <.link navigate={~p"/dashboard"} class="text-sm text-indigo-600 hover:text-indigo-800">
          &larr; Dashboard
        </.link>
        <h1 class="text-2xl font-bold text-gray-900 mt-2">Account Settings</h1>
        <p class="text-sm text-gray-500 mt-1">{@current_email}</p>
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

      <%!-- Email --%>
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
              New email
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
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
          >
            Change Email
          </button>
        </.form>
      </div>

      <%!-- Password --%>
      <div class="bg-white rounded-lg shadow p-6 mb-6">
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
            <p class="mt-1 text-xs text-gray-400">
              At least 12 characters, must include a letter and a number.
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
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
          >
            Save Password
          </button>
        </.form>
      </div>

      <%!-- Two-Factor Authentication --%>
      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Two-Factor Authentication</h2>
        <div :if={@totp_enabled} class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
              Enabled
            </span>
            <span class="text-sm text-gray-600">TOTP authenticator is active</span>
          </div>
        </div>
        <div :if={!@totp_enabled}>
          <p class="text-sm text-gray-600 mb-4">
            Add an extra layer of security by enabling two-factor authentication with an authenticator app (Google Authenticator, Authy, 1Password, etc.).
          </p>
          <.link
            navigate={~p"/auth/2fa/setup"}
            class="inline-flex items-center px-4 py-2 text-sm font-medium rounded-lg text-white bg-indigo-600 hover:bg-indigo-700"
          >
            Set Up 2FA
          </.link>
        </div>
      </div>

      <%!-- Passkeys / Security Keys --%>
      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-gray-900">Security Keys (Passkeys)</h2>
          <button
            phx-click="start_passkey_registration"
            class="text-sm text-indigo-600 hover:text-indigo-800 font-medium"
          >
            + Add Key
          </button>
        </div>
        <p class="text-sm text-gray-600 mb-4">
          Use a passkey (Bitwarden, 1Password, YubiKey, or your device) as a second factor when logging in.
        </p>

        <div
          :if={@passkey_challenge}
          id="passkey-register"
          phx-hook="PasskeyRegister"
          data-options={Jason.encode!(@passkey_options)}
          class="bg-indigo-50 border border-indigo-200 rounded-lg p-4 mb-4"
        >
          <p class="text-sm text-indigo-800 font-medium">
            Follow your browser's prompt to register your security key...
          </p>
        </div>

        <div :if={@passkeys == []} class="text-sm text-gray-500">
          No security keys registered.
        </div>
        <div :if={@passkeys != []} class="divide-y divide-gray-100">
          <div :for={key <- @passkeys} class="flex items-center justify-between py-3">
            <div>
              <span class="text-sm font-medium text-gray-900">{key.name}</span>
              <span class="text-xs text-gray-500 ml-2">
                Added {Calendar.strftime(key.inserted_at, "%Y-%m-%d")}
              </span>
            </div>
            <button
              phx-click="delete_passkey"
              phx-value-id={key.id}
              data-confirm={"Remove security key \"#{key.name}\"?"}
              class="text-red-500 hover:text-red-700 text-sm font-medium"
            >
              Remove
            </button>
          </div>
        </div>
      </div>

      <%!-- Session Preferences --%>
      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-4">Session Preferences</h2>
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm font-medium text-gray-700">Idle session timeout</p>
            <p class="text-xs text-gray-500">
              Automatically sign out after 30 minutes of inactivity.
            </p>
          </div>
          <button
            phx-click="toggle_idle_timeout"
            class={"relative inline-flex h-6 w-11 items-center rounded-full transition-colors " <>
              if(@current_scope.user.idle_timeout_disabled, do: "bg-gray-300", else: "bg-indigo-600")}
          >
            <span class={"inline-block h-4 w-4 transform rounded-full bg-white transition-transform " <>
              if(@current_scope.user.idle_timeout_disabled, do: "translate-x-1", else: "translate-x-6")} />
          </button>
        </div>
        <p :if={@current_scope.user.idle_timeout_disabled} class="text-xs text-amber-600 mt-2">
          Idle timeout is disabled. Your session will not expire due to inactivity.
        </p>
      </div>

      <%!-- API Keys --%>
      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-lg font-semibold text-gray-900">API Keys</h2>
          <button
            phx-click="toggle_api_form"
            class="text-sm text-indigo-600 hover:text-indigo-800 font-medium"
          >
            {if @show_api_form, do: "Cancel", else: "+ New Key"}
          </button>
        </div>

        <p class="text-sm text-gray-600 mb-4">
          Use API keys to access the Spectabas REST API. Keys start with <code class="text-xs bg-gray-100 px-1 rounded">sab_live_</code>.
        </p>

        <%!-- New key form --%>
        <div :if={@show_api_form} class="bg-gray-50 rounded-lg p-4 mb-4">
          <form phx-submit="create_api_key" class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Key Name</label>
              <input
                type="text"
                name="name"
                required
                placeholder="e.g. Production, CI/CD, My App"
                class="block w-full rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Permissions</label>
              <div class="grid grid-cols-2 sm:grid-cols-3 gap-2">
                <label
                  :for={scope <- Spectabas.Accounts.APIKey.valid_scopes()}
                  class="flex items-center gap-2 text-sm text-gray-700"
                >
                  <input
                    type="checkbox"
                    name="scopes[]"
                    value={scope}
                    checked={scope != "admin:sites"}
                    class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  {scope}
                </label>
              </div>
              <p class="text-xs text-gray-500 mt-1">
                admin:sites is not checked by default for security.
              </p>
            </div>

            <div :if={@user_sites != []}>
              <label class="block text-sm font-medium text-gray-700 mb-1">
                Restrict to Sites <span class="text-gray-400 font-normal">(optional)</span>
              </label>
              <div class="grid grid-cols-2 gap-2">
                <label
                  :for={site <- @user_sites}
                  class="flex items-center gap-2 text-sm text-gray-700"
                >
                  <input
                    type="checkbox"
                    name="site_ids[]"
                    value={site.id}
                    class="rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
                  />
                  {site.name}
                </label>
              </div>
              <p class="text-xs text-gray-500 mt-1">
                Leave all unchecked to allow access to all sites.
              </p>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">
                Expiry Date <span class="text-gray-400 font-normal">(optional)</span>
              </label>
              <input
                type="date"
                name="expires_at"
                min={Date.to_iso8601(Date.add(Date.utc_today(), 1))}
                class="block w-48 rounded-md border-gray-300 text-sm shadow-sm focus:border-indigo-500 focus:ring-indigo-500"
              />
            </div>

            <button
              type="submit"
              class="px-4 py-2 text-sm font-medium text-white bg-indigo-600 rounded-md hover:bg-indigo-700"
            >
              Generate Key
            </button>
          </form>
        </div>

        <%!-- Newly created key (shown once) --%>
        <div :if={@new_api_key} class="bg-green-50 border border-green-200 rounded-lg p-4 mb-4">
          <p class="text-sm text-green-800 font-medium mb-1">
            API key created! Copy it now — you won't see it again.
          </p>
          <code class="block bg-white border border-green-300 rounded p-2 text-sm font-mono text-green-900 break-all">
            {@new_api_key}
          </code>
        </div>

        <%!-- Key list --%>
        <div :if={@api_keys == []} class="text-sm text-gray-500">
          No API keys yet.
        </div>
        <div :if={@api_keys != []} class="divide-y divide-gray-100">
          <div :for={key <- @api_keys} class="py-3">
            <div class="flex items-center justify-between">
              <div>
                <span class="text-sm font-medium text-gray-900">{key.name}</span>
                <span class="text-xs text-gray-500 ml-2 font-mono">{key.key_prefix}...</span>
                <span :if={key.last_used_at} class="text-xs text-gray-400 ml-2">
                  Last used: {Calendar.strftime(key.last_used_at, "%Y-%m-%d")}
                </span>
                <span
                  :if={key.expires_at}
                  class={[
                    "text-xs ml-2 px-1.5 py-0.5 rounded",
                    if(DateTime.compare(key.expires_at, DateTime.utc_now()) == :lt,
                      do: "bg-red-100 text-red-700",
                      else: "bg-yellow-50 text-yellow-700"
                    )
                  ]}
                >
                  {if DateTime.compare(key.expires_at, DateTime.utc_now()) == :lt,
                    do: "Expired",
                    else: "Expires #{Calendar.strftime(key.expires_at, "%Y-%m-%d")}"}
                </span>
              </div>
              <button
                phx-click="revoke_api_key"
                phx-value-id={key.id}
                data-confirm={"Revoke API key \"#{key.name}\"? This cannot be undone."}
                class="text-red-500 hover:text-red-700 text-sm font-medium"
              >
                Revoke
              </button>
            </div>
            <div class="mt-1 flex flex-wrap gap-1">
              <span
                :for={scope <- key.scopes || []}
                class="text-[10px] px-1.5 py-0.5 rounded bg-indigo-50 text-indigo-700"
              >
                {scope}
              </span>
              <span
                :if={key.site_ids != nil and key.site_ids != []}
                class="text-[10px] px-1.5 py-0.5 rounded bg-orange-50 text-orange-700"
              >
                {length(key.site_ids)} site(s) only
              </span>
              <span
                :if={key.site_ids == nil or key.site_ids == []}
                class="text-[10px] px-1.5 py-0.5 rounded bg-gray-50 text-gray-500"
              >
                All sites
              </span>
            </div>
          </div>
        </div>
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
      |> assign(:totp_enabled, user.totp_enabled || false)
      |> assign(:show_api_form, false)
      |> assign(:new_api_key, nil)
      |> assign(:api_keys, APIKeys.list_user_keys(user))
      |> assign(:user_sites, Accounts.accessible_sites(user))
      |> assign(:passkeys, Webauthn.list_credentials(user))
      |> assign(:passkey_challenge, nil)
      |> assign(:passkey_options, nil)

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

  def handle_event("toggle_api_form", _params, socket) do
    {:noreply, assign(socket, :show_api_form, !socket.assigns.show_api_form)}
  end

  def handle_event("create_api_key", params, socket) do
    user = socket.assigns.current_scope.user
    name = params["name"] || ""

    scopes = params["scopes"] || []
    scopes = if scopes == [], do: nil, else: scopes

    site_ids =
      case params["site_ids"] do
        nil -> nil
        [] -> nil
        ids when is_list(ids) -> Enum.map(ids, &String.to_integer/1)
        _ -> nil
      end

    expires_at =
      case params["expires_at"] do
        "" ->
          nil

        nil ->
          nil

        date_str ->
          case Date.from_iso8601(date_str) do
            {:ok, date} -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
            _ -> nil
          end
      end

    opts =
      []
      |> then(fn o -> if scopes, do: [{:scopes, scopes} | o], else: o end)
      |> then(fn o -> if site_ids, do: [{:site_ids, site_ids} | o], else: o end)
      |> then(fn o -> if expires_at, do: [{:expires_at, expires_at} | o], else: o end)

    case APIKeys.generate(user, name, opts) do
      {:ok, plaintext, _api_key} ->
        {:noreply,
         socket
         |> assign(:new_api_key, plaintext)
         |> assign(:api_keys, APIKeys.list_user_keys(user))
         |> assign(:show_api_form, false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create API key.")}
    end
  end

  def handle_event("toggle_idle_timeout", _params, socket) do
    user = socket.assigns.current_scope.user
    new_val = !user.idle_timeout_disabled

    case Spectabas.Accounts.update_user_profile(user, %{idle_timeout_disabled: new_val}) do
      {:ok, updated} ->
        scope = %{socket.assigns.current_scope | user: updated}

        {:noreply,
         socket
         |> Phoenix.Component.assign(:current_scope, scope)
         |> Phoenix.LiveView.put_flash(
           :info,
           if(new_val, do: "Idle timeout disabled", else: "Idle timeout enabled")
         )}

      {:error, _} ->
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to update preference")}
    end
  end

  def handle_event("start_passkey_registration", _params, socket) do
    user = socket.assigns.current_scope.user
    {challenge, options} = Webauthn.registration_challenge(user)

    {:noreply,
     socket
     |> assign(:passkey_challenge, challenge)
     |> assign(:passkey_options, options)}
  end

  def handle_event(
        "passkey_registered",
        %{
          "attestation_object" => att_obj,
          "client_data_json" => cdj,
          "name" => name
        },
        socket
      ) do
    user = socket.assigns.current_scope.user
    challenge = socket.assigns.passkey_challenge

    case Webauthn.register(user, challenge, att_obj, cdj, name) do
      {:ok, _cred} ->
        {:noreply,
         socket
         |> put_flash(:info, "Security key registered successfully!")
         |> assign(:passkeys, Webauthn.list_credentials(user))
         |> assign(:passkey_challenge, nil)
         |> assign(:passkey_options, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to register key: #{inspect(reason)}")
         |> assign(:passkey_challenge, nil)
         |> assign(:passkey_options, nil)}
    end
  end

  def handle_event("delete_passkey", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Webauthn.delete_credential(user, id) do
      {:ok, _} ->
        user = socket.assigns.current_scope.user

        {:noreply,
         socket
         |> put_flash(:info, "Security key removed.")
         |> assign(:passkeys, Webauthn.list_credentials(user))}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to remove key.")}
    end
  end

  def handle_event("revoke_api_key", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    api_key = Spectabas.Repo.get!(Spectabas.Accounts.APIKey, id)

    case APIKeys.revoke(user, api_key) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "API key revoked.")
         |> assign(:api_keys, APIKeys.list_user_keys(user))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke API key.")}
    end
  end
end
