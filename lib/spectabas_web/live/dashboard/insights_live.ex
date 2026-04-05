defmodule SpectabasWeb.Dashboard.InsightsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Weekly actionable insights — automated analysis across all data sources."

  alias Spectabas.{Accounts, Sites}
  alias Spectabas.Analytics.AnomalyDetector
  import SpectabasWeb.Dashboard.SidebarComponent

  @categories [
    {"Immediate Action", [:high, :medium], "Issues requiring attention this week"},
    {"SEO Insights", nil, "Search ranking changes and optimization opportunities"},
    {"Traffic Trends", nil, "Visitor and engagement changes"},
    {"Revenue & Ads", nil, "Revenue, ad spend, and customer retention signals"},
    {"Opportunities", [:low, :info], "Positive trends and growth signals"}
  ]

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

      grouped = group_anomalies(anomalies)
      summary = build_summary(anomalies)

      {:ok,
       socket
       |> assign(:page_title, "Weekly Insights - #{site.name}")
       |> assign(:site, site)
       |> assign(:anomalies, anomalies)
       |> assign(:grouped, grouped)
       |> assign(:summary, summary)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout
      flash={@flash}
      site={@site}
      page_title="Weekly Insights"
      page_description="Actionable items from the last 7 days across traffic, SEO, revenue, and ads."
      active="insights"
      live_visitors={0}
    >
      <div class="max-w-4xl mx-auto px-3 sm:px-6 lg:px-8 py-6">
        <%!-- Summary cards --%>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-8">
          <div class="bg-white rounded-lg shadow p-4 border-l-4 border-red-400">
            <div class="text-2xl font-bold text-red-700">{@summary.alerts}</div>
            <div class="text-xs text-gray-500 mt-1">Alerts</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4 border-l-4 border-amber-400">
            <div class="text-2xl font-bold text-amber-700">{@summary.warnings}</div>
            <div class="text-xs text-gray-500 mt-1">Warnings</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4 border-l-4 border-blue-400">
            <div class="text-2xl font-bold text-blue-700">{@summary.seo_items}</div>
            <div class="text-xs text-gray-500 mt-1">SEO Items</div>
          </div>
          <div class="bg-white rounded-lg shadow p-4 border-l-4 border-green-400">
            <div class="text-2xl font-bold text-green-700">{@summary.opportunities}</div>
            <div class="text-xs text-gray-500 mt-1">Opportunities</div>
          </div>
        </div>

        <%= if @anomalies == [] do %>
          <div class="bg-white rounded-lg shadow p-8 text-center">
            <div class="text-4xl mb-3">&#10003;</div>
            <h3 class="text-lg font-semibold text-gray-900">All Clear</h3>
            <p class="text-sm text-gray-500 mt-1">
              No significant changes detected in the last 7 days compared to the week before.
            </p>
          </div>
        <% else %>
          <%!-- Grouped sections --%>
          <%= for {title, items, description} <- @grouped do %>
            <%= if items != [] do %>
              <div class="mb-8">
                <h2 class="text-lg font-semibold text-gray-900 mb-1">{title}</h2>
                <p class="text-xs text-gray-500 mb-4">{description}</p>
                <div class="space-y-3">
                  <div
                    :for={anomaly <- items}
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
                        <div class="min-w-0 flex-1">
                          <p class="text-sm font-medium text-gray-900">{anomaly.message}</p>
                          <p class="text-sm text-indigo-700 mt-1 bg-indigo-50 rounded px-2 py-1 inline-block">
                            {anomaly.action}
                          </p>
                          <div class="flex items-center gap-4 mt-2 text-xs text-gray-400">
                            <span class={"px-1.5 py-0.5 rounded " <> category_badge(anomaly.category)}>
                              {anomaly.category}
                            </span>
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
            <% end %>
          <% end %>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp group_anomalies(anomalies) do
    @categories
    |> Enum.map(fn {title, filter, description} ->
      items =
        case {title, filter} do
          {"Immediate Action", severities} ->
            Enum.filter(anomalies, &(&1.severity in severities and &1.category not in ["seo"]))

          {"SEO Insights", _} ->
            Enum.filter(anomalies, &(&1.category == "seo"))

          {"Traffic Trends", _} ->
            Enum.filter(anomalies, &(&1.category in ["traffic", "engagement", "sources", "pages"] and &1.severity not in [:high, :medium]))

          {"Revenue & Ads", _} ->
            Enum.filter(anomalies, &(&1.category in ["revenue", "advertising", "retention", "ad traffic"] and &1.severity not in [:high, :medium]))

          {"Opportunities", severities} ->
            Enum.filter(anomalies, &(&1.severity in severities and &1.category not in ["seo", "traffic", "engagement", "sources", "pages", "revenue", "advertising", "retention", "ad traffic"]))

          _ ->
            []
        end

      {title, items, description}
    end)
  end

  defp build_summary(anomalies) do
    %{
      alerts: Enum.count(anomalies, &(&1.severity == :high)),
      warnings: Enum.count(anomalies, &(&1.severity == :medium)),
      seo_items: Enum.count(anomalies, &(&1.category == "seo")),
      opportunities: Enum.count(anomalies, &(&1.severity in [:low, :info]))
    }
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

  defp category_badge("seo"), do: "bg-green-50 text-green-700"
  defp category_badge("traffic"), do: "bg-blue-50 text-blue-700"
  defp category_badge("engagement"), do: "bg-purple-50 text-purple-700"
  defp category_badge("revenue"), do: "bg-emerald-50 text-emerald-700"
  defp category_badge("advertising"), do: "bg-amber-50 text-amber-700"
  defp category_badge("retention"), do: "bg-red-50 text-red-700"
  defp category_badge(_), do: "bg-gray-50 text-gray-600"
end
