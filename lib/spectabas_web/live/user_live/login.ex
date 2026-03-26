defmodule SpectabasWeb.UserLive.Login do
  use SpectabasWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gray-50 py-12 px-4 sm:px-6 lg:px-8">
      <div class="max-w-md w-full space-y-8">
        <div class="text-center">
          <h1 class="text-3xl font-bold text-indigo-600">Spectabas</h1>
          <h2 class="mt-4 text-xl font-semibold text-gray-900">Sign in to your account</h2>
        </div>

        <p
          :if={msg = Phoenix.Flash.get(@flash, :info)}
          class="rounded-lg bg-blue-50 p-3 text-sm text-blue-700 text-center"
        >
          {msg}
        </p>
        <p
          :if={msg = Phoenix.Flash.get(@flash, :error)}
          class="rounded-lg bg-red-50 p-3 text-sm text-red-700 text-center"
        >
          {msg}
        </p>

        <.form
          for={@form}
          id="login_form"
          action={~p"/users/log-in"}
          phx-submit="submit"
          phx-trigger-action={@trigger_submit}
          class="mt-8 space-y-6 bg-white shadow-lg rounded-xl p-8"
        >
          <div class="space-y-4">
            <div>
              <label for="user_email" class="block text-sm font-medium text-gray-700">
                Email address
              </label>
              <input
                id="user_email"
                name={@form[:email].name}
                type="email"
                value={@form[:email].value}
                autocomplete="username"
                required
                phx-mounted={JS.focus()}
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                placeholder="you@example.com"
              />
            </div>

            <div>
              <label for="user_password" class="block text-sm font-medium text-gray-700">
                Password
              </label>
              <input
                id="user_password"
                name={@form[:password].name}
                type="password"
                autocomplete="current-password"
                required
                class="mt-1 block w-full rounded-lg border-gray-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm px-3 py-2.5"
                placeholder="Enter your password"
              />
            </div>
          </div>

          <div class="flex items-center justify-between">
            <div class="flex items-center">
              <input
                id="remember_me"
                name={@form[:remember_me].name}
                type="checkbox"
                value="true"
                class="h-4 w-4 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500"
              />
              <label for="remember_me" class="ml-2 block text-sm text-gray-700">
                Keep me signed in
              </label>
            </div>
          </div>

          <button
            type="submit"
            class="w-full flex justify-center py-2.5 px-4 border border-transparent rounded-lg shadow-sm text-sm font-semibold text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500 transition"
          >
            Sign in
          </button>
        </.form>

        <p class="text-center text-sm text-gray-500">
          Contact your administrator for account access.
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")
    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
