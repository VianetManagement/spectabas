defmodule SpectabasWeb.Platform.DashboardLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Repo}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    total_accounts = Repo.aggregate(Accounts.Account, :count)
    total_sites = Repo.aggregate(Sites.Site, :count)
    total_users = Repo.aggregate(Accounts.User, :count)
    accounts = Accounts.list_accounts()

    account_stats =
      Enum.map(accounts, fn acct ->
        sites = Repo.aggregate(from(s in Sites.Site, where: s.account_id == ^acct.id), :count)
        users = Repo.aggregate(from(u in Accounts.User, where: u.account_id == ^acct.id), :count)
        %{account: acct, sites: sites, users: users}
      end)

    {:ok,
     socket
     |> assign(:page_title, "Platform Administration")
     |> assign(:total_accounts, total_accounts)
     |> assign(:total_sites, total_sites)
     |> assign(:total_users, total_users)
     |> assign(:account_stats, account_stats)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto py-8 px-4">
      <h1 class="text-2xl font-bold text-gray-900 mb-6">Platform Administration</h1>

      <div class="grid grid-cols-3 gap-4 mb-8">
        <div class="bg-white border rounded-lg p-4">
          <div class="text-sm text-gray-500">Total Accounts</div>
          <div class="text-3xl font-bold text-purple-600">{@total_accounts}</div>
        </div>
        <div class="bg-white border rounded-lg p-4">
          <div class="text-sm text-gray-500">Total Sites</div>
          <div class="text-3xl font-bold text-indigo-600">{@total_sites}</div>
        </div>
        <div class="bg-white border rounded-lg p-4">
          <div class="text-sm text-gray-500">Total Users</div>
          <div class="text-3xl font-bold text-blue-600">{@total_users}</div>
        </div>
      </div>

      <div class="flex items-center justify-between mb-4">
        <h2 class="text-lg font-semibold text-gray-800">Accounts</h2>
        <a href="/platform/accounts" class="text-sm text-indigo-600 hover:text-indigo-800 font-medium">
          Manage Accounts &rarr;
        </a>
      </div>

      <div class="bg-white border rounded-lg overflow-hidden">
        <table class="w-full text-sm">
          <thead class="bg-gray-50 border-b">
            <tr>
              <th class="text-left px-4 py-2 font-medium text-gray-700">Account</th>
              <th class="text-left px-4 py-2 font-medium text-gray-700">Slug</th>
              <th class="text-right px-4 py-2 font-medium text-gray-700">Sites</th>
              <th class="text-right px-4 py-2 font-medium text-gray-700">Limit</th>
              <th class="text-right px-4 py-2 font-medium text-gray-700">Users</th>
              <th class="text-center px-4 py-2 font-medium text-gray-700">Status</th>
            </tr>
          </thead>
          <tbody>
            <%= for stat <- @account_stats do %>
              <tr class="border-b hover:bg-gray-50">
                <td class="px-4 py-2">
                  <a
                    href={"/platform/accounts/#{stat.account.id}"}
                    class="text-indigo-600 hover:text-indigo-800 font-medium"
                  >
                    {stat.account.name}
                  </a>
                </td>
                <td class="px-4 py-2 text-gray-500">{stat.account.slug}</td>
                <td class="text-right px-4 py-2">{stat.sites}</td>
                <td class="text-right px-4 py-2 text-gray-500">{stat.account.site_limit}</td>
                <td class="text-right px-4 py-2">{stat.users}</td>
                <td class="text-center px-4 py-2">
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
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>

      <div class="mt-8 grid grid-cols-2 gap-4">
        <a
          href="/admin/ingest"
          class="block bg-white border rounded-lg p-4 hover:border-indigo-300"
        >
          <div class="font-medium text-gray-900">Ingest Diagnostics</div>
          <div class="text-sm text-gray-500">BEAM memory, buffer, ClickHouse pool</div>
        </a>
        <a
          href="/platform/spam-filter"
          class="block bg-white border rounded-lg p-4 hover:border-indigo-300"
        >
          <div class="font-medium text-gray-900">Spam Filter</div>
          <div class="text-sm text-gray-500">Manage referrer domain blocklist</div>
        </a>
        <a
          href="/admin/api-logs"
          class="block bg-white border rounded-lg p-4 hover:border-indigo-300"
        >
          <div class="font-medium text-gray-900">API Logs</div>
          <div class="text-sm text-gray-500">Request/response detail, 30-day retention</div>
        </a>
        <a
          href="/platform/competitive"
          class="block bg-white border rounded-lg p-4 hover:border-indigo-300"
        >
          <div class="font-medium text-gray-900">Competitive Analysis</div>
          <div class="text-sm text-gray-500">Market positioning and features</div>
        </a>
      </div>
    </div>
    """
  end
end
