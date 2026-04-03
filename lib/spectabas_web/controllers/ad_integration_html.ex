defmodule SpectabasWeb.AdIntegrationHTML do
  use SpectabasWeb, :html

  def pick_account(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50 flex items-center justify-center py-12 px-4">
      <div class="max-w-md w-full bg-white rounded-lg shadow-sm border border-gray-200 p-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-1">Select Google Ads Account</h2>
        <p class="text-sm text-gray-500 mb-5">
          Multiple accounts were found. Choose which one to connect:
        </p>

        <div class="space-y-2">
          <%= for customer <- @customers do %>
            <form method="post" action={~p"/auth/ad/google_ads/select_account"}>
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <input type="hidden" name="site_id" value={@site_id} />
              <input type="hidden" name="account_id" value={customer["id"] || customer[:id]} />
              <button
                type="submit"
                class="w-full text-left px-4 py-3 rounded-md border border-gray-200 hover:border-indigo-300 hover:bg-indigo-50 transition-colors"
              >
                <div class="font-medium text-gray-900">
                  {customer["name"] || customer[:name] || customer["id"] || customer[:id]}
                </div>
                <div class="text-xs text-gray-500 mt-0.5">
                  ID: {customer["id"] || customer[:id]}
                </div>
              </button>
            </form>
          <% end %>
        </div>

        <div class="mt-5 text-center">
          <.link
            navigate={~p"/dashboard/sites/#{@site_id}/settings"}
            class="text-sm text-gray-500 hover:text-gray-700"
          >
            Cancel
          </.link>
        </div>
      </div>
    </div>
    """
  end

  def meta_pick_account(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50 flex items-center justify-center py-12 px-4">
      <div class="max-w-md w-full bg-white rounded-lg shadow-sm border border-gray-200 p-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-1">Select Meta Ad Account</h2>
        <p class="text-sm text-gray-500 mb-5">
          Multiple ad accounts were found. Choose which one to connect:
        </p>

        <div class="space-y-2">
          <%= for account <- @accounts do %>
            <form method="post" action={~p"/auth/ad/meta_ads/select_account"}>
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <input type="hidden" name="site_id" value={@site_id} />
              <input type="hidden" name="account_id" value={account["id"] || account[:id]} />
              <button
                type="submit"
                class="w-full text-left px-4 py-3 rounded-md border border-gray-200 hover:border-indigo-300 hover:bg-indigo-50 transition-colors"
              >
                <div class="font-medium text-gray-900">
                  {account["name"] || account[:name] || account["id"] || account[:id]}
                </div>
                <div class="text-xs text-gray-500 mt-0.5">
                  ID: {account["id"] || account[:id]}
                  <%= if currency = account["currency"] || account[:currency] do %>
                    <span class="ml-2">({currency})</span>
                  <% end %>
                </div>
              </button>
            </form>
          <% end %>
        </div>

        <div class="mt-5 text-center">
          <.link
            navigate={~p"/dashboard/sites/#{@site_id}/settings"}
            class="text-sm text-gray-500 hover:text-gray-700"
          >
            Cancel
          </.link>
        </div>
      </div>
    </div>
    """
  end

  def bing_pick_account(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50 flex items-center justify-center py-12 px-4">
      <div class="max-w-md w-full bg-white rounded-lg shadow-sm border border-gray-200 p-6">
        <h2 class="text-lg font-semibold text-gray-900 mb-1">Select Microsoft Ads Account</h2>
        <p class="text-sm text-gray-500 mb-5">
          Multiple ad accounts were found. Choose which one to connect:
        </p>

        <div class="space-y-2">
          <%= for account <- @accounts do %>
            <form method="post" action={~p"/auth/ad/bing_ads/select_account"}>
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <input type="hidden" name="site_id" value={@site_id} />
              <input type="hidden" name="account_id" value={account["id"] || account[:id]} />
              <button
                type="submit"
                class="w-full text-left px-4 py-3 rounded-md border border-gray-200 hover:border-indigo-300 hover:bg-indigo-50 transition-colors"
              >
                <div class="font-medium text-gray-900">
                  {account["name"] || account[:name] || account["id"] || account[:id]}
                </div>
                <div class="text-xs text-gray-500 mt-0.5">
                  ID: {account["id"] || account[:id]}
                  <%= if number = account["number"] || account[:number] do %>
                    <span class="ml-2">(#{number})</span>
                  <% end %>
                </div>
              </button>
            </form>
          <% end %>
        </div>

        <div class="mt-5 text-center">
          <.link
            navigate={~p"/dashboard/sites/#{@site_id}/settings"}
            class="text-sm text-gray-500 hover:text-gray-700"
          >
            Cancel
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
