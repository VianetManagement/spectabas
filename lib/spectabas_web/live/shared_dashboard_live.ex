defmodule SpectabasWeb.SharedDashboardLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Repo, Analytics}
  alias Spectabas.Sites
  alias Spectabas.Sites.SharedLink
  import Ecto.Query

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case get_valid_shared_link(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "This shared link is invalid, expired, or has been revoked.")
         |> redirect(to: ~p"/")}

      shared_link ->
        site = Sites.get_site!(shared_link.site_id)

        {:ok,
         socket
         |> assign(:page_title, "#{site.name} - Shared Dashboard")
         |> assign(:site, site)
         |> assign(:shared_link, shared_link)
         |> assign(:date_range, "7d")
         |> load_stats()}
    end
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_stats()}
  end

  defp load_stats(socket) do
    %{site: site, date_range: range} = socket.assigns

    # Shared dashboards use a public query variant that does not require a user.
    stats =
      case Analytics.overview_stats_public(site, range_to_atom(range)) do
        {:ok, data} -> data
        _ -> %{pageviews: 0, unique_visitors: 0, sessions: 0, bounce_rate: 0.0, avg_duration: 0}
      end

    assign(socket, :stats, stats)
  end

  defp range_to_atom("24h"), do: :day
  defp range_to_atom("7d"), do: :week
  defp range_to_atom("30d"), do: :month
  defp range_to_atom(_), do: :week

  defp get_valid_shared_link(token) when is_binary(token) do
    now = DateTime.utc_now()

    Repo.one(
      from(sl in SharedLink,
        where: sl.token == ^token,
        where: is_nil(sl.revoked_at),
        where: is_nil(sl.expires_at) or sl.expires_at > ^now
      )
    )
  end

  defp get_valid_shared_link(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 class="text-2xl font-bold text-gray-900">{@site.name}</h1>
          <p class="text-sm text-gray-500">{@site.domain} — shared dashboard (read-only)</p>
        </div>
        <nav class="flex gap-1 bg-gray-100 rounded-lg p-1">
          <button
            :for={r <- [{"24h", "24h"}, {"7d", "7 days"}, {"30d", "30 days"}]}
            phx-click="change_range"
            phx-value-range={elem(r, 0)}
            class={[
              "px-3 py-1.5 text-sm font-medium rounded-md",
              if(@date_range == elem(r, 0),
                do: "bg-white shadow text-gray-900",
                else: "text-gray-600 hover:text-gray-900"
              )
            ]}
          >
            {elem(r, 1)}
          </button>
        </nav>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
        <.stat_card label="Pageviews" value={@stats.pageviews} />
        <.stat_card label="Unique Visitors" value={@stats.unique_visitors} />
        <.stat_card label="Sessions" value={@stats.sessions} />
        <.stat_card label="Bounce Rate" value={"#{@stats.bounce_rate}%"} />
        <.stat_card label="Avg Duration" value={format_duration(@stats.avg_duration)} />
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="bg-white rounded-lg shadow p-4">
      <dt class="text-sm font-medium text-gray-500 truncate">{@label}</dt>
      <dd class="mt-1 text-2xl font-bold text-gray-900">{@value}</dd>
    </div>
    """
  end

  defp format_duration(seconds) when is_number(seconds) do
    minutes = div(trunc(seconds), 60)
    secs = rem(trunc(seconds), 60)
    "#{minutes}m #{secs}s"
  end

  defp format_duration(_), do: "0m 0s"
end
