defmodule SpectabasWeb.Auth.TOTPVerifyLive do
  use SpectabasWeb, :live_view

  alias Spectabas.Accounts.TOTP

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    unless user.totp_enabled do
      {:ok,
       socket
       |> put_flash(:info, "Two-factor authentication is not enabled.")
       |> redirect(to: ~p"/dashboard")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Verify 2FA")
       |> assign(:user, user)
       |> assign(:code, "")
       |> assign(:error, nil)}
    end
  end

  @impl true
  def handle_event("update_code", %{"code" => code}, socket) do
    {:noreply, assign(socket, :code, code)}
  end

  def handle_event("verify", %{"code" => code}, socket) do
    code = String.trim(code)

    case TOTP.verify(socket.assigns.user, code) do
      :ok ->
        # Redirect through controller to set totp_verified_at session flag
        {:noreply, redirect(socket, to: ~p"/auth/2fa/verified")}

      {:error, :invalid_code} ->
        {:noreply, assign(socket, :error, "Invalid code. Please try again.")}

      {:error, :totp_not_enabled} ->
        {:noreply,
         socket
         |> put_flash(:error, "2FA is not enabled for your account.")
         |> redirect(to: ~p"/dashboard")}

      {:error, _reason} ->
        {:noreply, assign(socket, :error, "An error occurred. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gray-50 px-4">
      <div class="max-w-sm w-full">
        <div class="text-center mb-8">
          <h1 class="text-2xl font-bold text-gray-900">Two-Factor Authentication</h1>
          <p class="text-sm text-gray-500 mt-2">
            Enter the 6-digit code from your authenticator app to continue.
          </p>
        </div>

        <div class="bg-white rounded-lg shadow p-6">
          <form phx-submit="verify" phx-change="update_code" class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-gray-700 sr-only">Verification Code</label>
              <input
                type="text"
                name="code"
                value={@code}
                autocomplete="one-time-code"
                inputmode="numeric"
                pattern="[0-9]*"
                maxlength="6"
                required
                autofocus
                class="block w-full rounded-md border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 text-center text-2xl tracking-widest py-3"
                placeholder="000000"
              />
            </div>
            <p :if={@error} class="text-sm text-red-600 text-center">{@error}</p>
            <button
              type="submit"
              class="w-full inline-flex justify-center items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-indigo-600 hover:bg-indigo-700"
            >
              Verify
            </button>
          </form>
        </div>

        <p class="text-center mt-4 text-sm text-gray-500">
          Lost access to your authenticator? Contact your administrator.
        </p>
      </div>
    </div>
    """
  end
end
