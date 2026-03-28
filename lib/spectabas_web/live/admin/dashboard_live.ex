defmodule SpectabasWeb.Admin.DashboardLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Sites, Accounts, Analytics, Repo}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    total_sites = Repo.aggregate(Sites.Site, :count, :id)
    total_users = Repo.aggregate(Accounts.User, :count, :id)

    events_today =
      case Analytics.total_events_today() do
        {:ok, count} -> count
        _ -> 0
      end

    failed_events =
      Repo.aggregate(
        from(fe in Spectabas.Events.FailedEvent, where: fe.attempts < 10),
        :count,
        :id
      )

    {:ok,
     socket
     |> assign(:page_title, "Admin Dashboard")
     |> assign(:total_sites, total_sites)
     |> assign(:total_users, total_users)
     |> assign(:events_today, events_today)
     |> assign(:failed_events, failed_events)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <h1 class="text-2xl font-bold text-gray-900 mb-8">Admin Dashboard</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <div class="bg-white rounded-lg shadow p-6">
          <dt class="text-sm font-medium text-gray-500">Total Sites</dt>
          <dd class="mt-2 text-3xl font-bold text-gray-900">{@total_sites}</dd>
          <.link
            navigate={~p"/admin/sites"}
            class="mt-2 text-sm text-indigo-600 hover:text-indigo-800 block"
          >
            Manage sites &rarr;
          </.link>
        </div>
        <div class="bg-white rounded-lg shadow p-6">
          <dt class="text-sm font-medium text-gray-500">Total Users</dt>
          <dd class="mt-2 text-3xl font-bold text-gray-900">{@total_users}</dd>
          <.link
            navigate={~p"/admin/users"}
            class="mt-2 text-sm text-indigo-600 hover:text-indigo-800 block"
          >
            Manage users &rarr;
          </.link>
        </div>
        <div class="bg-white rounded-lg shadow p-6">
          <dt class="text-sm font-medium text-gray-500">Events Today</dt>
          <dd class="mt-2 text-3xl font-bold text-gray-900">{@events_today}</dd>
        </div>
        <div class="bg-white rounded-lg shadow p-6">
          <dt class="text-sm font-medium text-gray-500">Failed Events</dt>
          <dd class={[
            "mt-2 text-3xl font-bold",
            if(@failed_events > 0, do: "text-red-600", else: "text-gray-900")
          ]}>
            {@failed_events}
          </dd>
        </div>
      </div>

      <div class="mt-8 grid grid-cols-1 md:grid-cols-2 gap-6">
        <.link
          navigate={~p"/admin/audit"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-1">Audit Log</h3>
          <p class="text-sm text-gray-500">View all system events and actions</p>
        </.link>
        <.link
          navigate={~p"/admin/changelog"}
          class="block bg-white rounded-lg shadow p-6 hover:shadow-md transition-shadow"
        >
          <h3 class="font-semibold text-gray-900 mb-1">Changelog</h3>
          <p class="text-sm text-gray-500">Recent changes and new features</p>
        </.link>
      </div>
    </div>
    """
  end
end
