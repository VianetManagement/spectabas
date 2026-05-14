defmodule SpectabasWeb.Dashboard.InsightsFeedLive do
  @moduledoc """
  Full-page feed of `Spectabas.Insights.Insight` rows for one site.
  Shows insights the current user hasn't dismissed, newest first. Click
  the X to dismiss (per-user; the row stays in PG and may still be
  visible to other team members).

  This is the destination for the "View all" link on the Dashboard
  overview's compact insights card.
  """
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites, Insights}
  import SpectabasWeb.Dashboard.SidebarComponent
  import SpectabasWeb.InsightCard

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    if !Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Insights - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:insights, load_insights(site.id, user.id))}
    end
  end

  defp load_insights(site_id, user_id) do
    Insights.list_active_for_user(site_id, user_id, limit: 50)
  end

  @impl true
  def handle_event("dismiss_insight", %{"id" => id}, socket) do
    {id_int, _} = Integer.parse(id)
    Insights.dismiss(id_int, socket.assigns.user.id)

    {:noreply,
     assign(socket, :insights, load_insights(socket.assigns.site.id, socket.assigns.user.id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Insights"
      page_description="What changed across your site, with AI explanations and action ideas."
      active="insights"
      live_visitors={0}
    >
      <div class="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-6">
          <h1 class="text-2xl font-bold text-gray-900">What's happening</h1>
          <p class="text-sm text-gray-500 mt-1">
            Generated daily from anomaly detection + goal pace changes. Click ✕ to dismiss for yourself.
          </p>
        </div>

        <div :if={@insights == []} class="bg-white rounded-lg shadow p-10 text-center">
          <p class="text-sm text-gray-500">
            No active insights right now. New signals show up here as the daily generator runs.
          </p>
        </div>

        <div :if={@insights != []} class="space-y-3">
          <.insight_card :for={insight <- @insights} insight={insight} />
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
