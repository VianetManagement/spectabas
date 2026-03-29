defmodule SpectabasWeb.Dashboard.InsightsLive do
  use SpectabasWeb, :live_view

  alias Spectabas.{Accounts, Sites}
  alias Spectabas.Analytics.AnomalyDetector
  import SpectabasWeb.Dashboard.SidebarComponent

  @impl true
  def mount(%{"site_id" => site_id}, _session, socket) do
    user = socket.assigns.current_scope.user
    site = Sites.get_site!(site_id)

    unless Accounts.can_access_site?(user, site) do
      {:ok, socket |> put_flash(:error, "Unauthorized") |> redirect(to: ~p"/")}
    else
      anomalies =
        case AnomalyDetector.detect(site, user) do
          {:ok, results} -> results
          _ -> []
        end

      {:ok,
       socket
       |> assign(:page_title, "Insights - #{site.name}")
       |> assign(:site, site)
       |> assign(:anomalies, anomalies)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      site={@site}
      page_title="Insights & Alerts"
      page_description="Automated analysis of your traffic patterns. Detects significant changes and suggests actions."
      active="insights"
      live_visitors={0}
    >
      <div class="max-w-4xl mx-auto px-3 sm:px-6 lg:px-8 py-6">
        <div :if={@anomalies == []} class="bg-white rounded-lg shadow p-8 text-center">
          <div class="text-4xl mb-3">&#10003;</div>
          <h3 class="text-lg font-semibold text-gray-900">All Clear</h3>
          <p class="text-sm text-gray-500 mt-1">
            No significant changes detected in the last 7 days compared to the week before.
          </p>
        </div>

        <div :if={@anomalies != []} class="space-y-4">
          <div
            :for={anomaly <- @anomalies}
            class={[
              "bg-white rounded-lg shadow overflow-hidden border-l-4",
              severity_border(anomaly.severity)
            ]}
          >
            <div class="p-4 sm:p-5">
              <div class="flex items-start gap-3">
                <span class={[
                  "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium shrink-0 mt-0.5",
                  severity_badge(anomaly.severity)
                ]}>
                  {severity_label(anomaly.severity)}
                </span>
                <div class="min-w-0">
                  <p class="text-sm font-medium text-gray-900">{anomaly.message}</p>
                  <p class="text-sm text-gray-500 mt-1">{anomaly.action}</p>
                  <div class="flex items-center gap-4 mt-2 text-xs text-gray-400">
                    <span class="capitalize">{anomaly.category}</span>
                    <span :if={anomaly.change_pct}>
                      {if anomaly.change_pct > 0, do: "+", else: ""}{anomaly.change_pct}%
                    </span>
                    <span :if={anomaly.previous}>
                      {anomaly.previous} → {anomaly.current}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </.dashboard_layout>
    """
  end

  defp severity_border(:high), do: "border-red-500"
  defp severity_border(:medium), do: "border-amber-500"
  defp severity_border(:low), do: "border-blue-400"
  defp severity_border(:info), do: "border-green-400"
  defp severity_border(_), do: "border-gray-300"

  defp severity_badge(:high), do: "bg-red-100 text-red-800"
  defp severity_badge(:medium), do: "bg-amber-100 text-amber-800"
  defp severity_badge(:low), do: "bg-blue-100 text-blue-800"
  defp severity_badge(:info), do: "bg-green-100 text-green-800"
  defp severity_badge(_), do: "bg-gray-100 text-gray-800"

  defp severity_label(:high), do: "Alert"
  defp severity_label(:medium), do: "Warning"
  defp severity_label(:low), do: "Notice"
  defp severity_label(:info), do: "Info"
  defp severity_label(_), do: "Info"
end
