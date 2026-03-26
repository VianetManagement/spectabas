defmodule SpectabasWeb.Auth.TOTPSetupLive do
  use SpectabasWeb, :live_view

  alias Spectabas.Accounts.TOTP

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    if user.totp_enabled do
      {:ok,
       socket
       |> put_flash(:info, "Two-factor authentication is already enabled.")
       |> redirect(to: ~p"/users/settings")}
    else
      case TOTP.setup(user) do
        {:ok, updated_user, uri} ->
          {:ok,
           socket
           |> assign(:page_title, "Set Up 2FA")
           |> assign(:user, updated_user)
           |> assign(:totp_uri, uri)
           |> assign(:code, "")
           |> assign(:error, nil)}

        {:error, _reason} ->
          {:ok,
           socket
           |> put_flash(:error, "Failed to initialize 2FA setup.")
           |> redirect(to: ~p"/users/settings")}
      end
    end
  end

  @impl true
  def handle_event("update_code", %{"code" => code}, socket) do
    {:noreply, assign(socket, :code, code)}
  end

  def handle_event("verify", %{"code" => code}, socket) do
    code = String.trim(code)

    case TOTP.verify_and_enable(socket.assigns.user, code) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Two-factor authentication enabled successfully.")
         |> redirect(to: ~p"/users/settings")}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, :error, "Invalid verification code. Please try again.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, "An error occurred. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-lg mx-auto px-4 sm:px-6 lg:px-8 py-12">
      <h1 class="text-2xl font-bold text-gray-900 mb-2">Set Up Two-Factor Authentication</h1>
      <p class="text-sm text-gray-500 mb-8">
        Scan the QR code below with your authenticator app (Google Authenticator, Authy, 1Password, etc.),
        then enter the verification code to confirm.
      </p>

      <div class="bg-white rounded-lg shadow p-6 mb-6">
        <div class="flex flex-col items-center mb-6">
          <div class="bg-white p-4 rounded-lg border-2 border-gray-200 mb-4">
            <p class="text-sm text-gray-600 text-center mb-2">
              Scan this QR code with your authenticator app:
            </p>
            <div class="flex justify-center">
              <img
                src={"https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=#{URI.encode(@totp_uri)}"}
                alt="TOTP QR Code"
                class="w-48 h-48"
              />
            </div>
          </div>
          <details class="w-full">
            <summary class="text-sm text-indigo-600 hover:text-indigo-800 cursor-pointer">
              Can't scan? Enter the key manually
            </summary>
            <div class="mt-2 p-3 bg-gray-50 rounded-lg">
              <code class="text-xs text-gray-700 break-all">{@totp_uri}</code>
            </div>
          </details>
        </div>

        <form phx-submit="verify" phx-change="update_code" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-gray-700">Verification Code</label>
            <input
              type="text"
              name="code"
              value={@code}
              autocomplete="one-time-code"
              inputmode="numeric"
              pattern="[0-9]*"
              maxlength="6"
              required
              class="mt-1 block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm text-center text-lg tracking-widest"
              placeholder="000000"
            />
          </div>
          <p :if={@error} class="text-sm text-red-600">{@error}</p>
          <button
            type="submit"
            class="w-full inline-flex justify-center items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
          >
            Verify and Enable 2FA
          </button>
        </form>
      </div>

      <.link navigate={~p"/users/settings"} class="text-sm text-gray-500 hover:text-gray-700">
        &larr; Back to settings
      </.link>
    </div>
    """
  end
end
