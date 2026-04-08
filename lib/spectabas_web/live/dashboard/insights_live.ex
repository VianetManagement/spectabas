defmodule SpectabasWeb.Dashboard.InsightsLive do
  use SpectabasWeb, :live_view

  @moduledoc "Weekly actionable insights — automated analysis across all data sources."

  alias Spectabas.{Accounts, Sites}
  alias Spectabas.Analytics.AnomalyDetector
  alias Spectabas.AI.{Config, InsightsCache}
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

      # Check for cached AI analysis
      ai_configured = Config.configured?(site)

      # Debug: log AI config state
      require Logger
      ai_config = Config.get(site)

      Logger.info(
        "[Insights] AI configured=#{ai_configured}, provider=#{ai_config["provider"]}, has_key=#{ai_config["api_key"] != nil and ai_config["api_key"] != ""}, encrypted_field=#{site.ai_config_encrypted != nil}"
      )

      cached_ai = if ai_configured, do: InsightsCache.get(site.id), else: nil

      {:ok,
       socket
       |> assign(:page_title, "Weekly Insights - #{site.name}")
       |> assign(:site, site)
       |> assign(:user, user)
       |> assign(:anomalies, anomalies)
       |> assign(:grouped, grouped)
       |> assign(:summary, summary)
       |> assign(:ai_configured, ai_configured)
       |> assign(:ai_analysis, if(cached_ai, do: cached_ai.content, else: nil))
       |> assign(:ai_generated_at, if(cached_ai, do: cached_ai.generated_at, else: nil))
       |> assign(:ai_loading, false)
       |> assign(:ai_error, nil)}
    end
  end

  @impl true
  def handle_event("generate_ai", _params, socket) do
    site = socket.assigns.site
    user = socket.assigns.user
    socket = assign(socket, :ai_loading, true)

    # Run async to not block the UI
    send(self(), {:run_ai_analysis, site, user})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_ai_analysis, site, user}, socket) do
    prompt = Spectabas.AI.InsightsPrompt.build(site, user)
    system = Spectabas.AI.InsightsPrompt.system_prompt()

    {provider, _key, model} = Config.credentials(site)

    result =
      case Spectabas.AI.Completion.generate(site, system, prompt) do
        {:ok, text} ->
          InsightsCache.put(site.id, text, provider, model)
          {:ok, text}

        {:error, reason} ->
          {:error, reason}
      end

    socket =
      case result do
        {:ok, text} ->
          socket
          |> assign(:ai_analysis, text)
          |> assign(:ai_generated_at, DateTime.utc_now() |> DateTime.truncate(:second))
          |> assign(:ai_loading, false)
          |> assign(:ai_error, nil)

        {:error, reason} ->
          socket
          |> assign(:ai_loading, false)
          |> assign(:ai_error, reason)
      end

    {:noreply, socket}
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

        <%!-- AI Analysis section --%>
        <div class="bg-white rounded-lg shadow mb-8">
          <div class="px-6 py-4 border-b border-gray-200 flex items-center justify-between">
            <div>
              <h2 class="text-lg font-semibold text-gray-900">AI Analysis</h2>
              <p class="text-xs text-gray-500">AI-generated insights from all your data sources</p>
            </div>
            <%= if @ai_configured do %>
              <button
                phx-click="generate_ai"
                disabled={@ai_loading}
                class={"px-4 py-2 text-sm font-medium rounded-lg text-white transition " <>
                  if(@ai_loading, do: "bg-gray-400 cursor-wait", else: "bg-indigo-600 hover:bg-indigo-700")}
              >
                <%= if @ai_loading do %>
                  Analyzing...
                <% else %>
                  {if @ai_analysis, do: "Regenerate", else: "Generate Analysis"}
                <% end %>
              </button>
            <% else %>
              <.link
                navigate={~p"/dashboard/sites/#{@site.id}/settings"}
                class="text-sm text-indigo-600 hover:text-indigo-800"
              >
                Configure AI Provider &rarr;
              </.link>
            <% end %>
          </div>
          <div class="p-6">
            <%= if @ai_error do %>
              <p class="text-sm text-red-600">{@ai_error}</p>
            <% end %>
            <%= if @ai_loading do %>
              <div class="flex items-center gap-3 text-gray-500">
                <div class="animate-spin h-5 w-5 border-2 border-indigo-600 border-t-transparent rounded-full">
                </div>
                <span class="text-sm">
                  Analyzing your data across traffic, SEO, revenue, and ad spend...
                </span>
              </div>
            <% end %>
            <%= if @ai_analysis do %>
              <div class="prose prose-sm max-w-none">
                {Phoenix.HTML.raw(render_markdown(@ai_analysis))}
              </div>
              <p :if={@ai_generated_at} class="text-xs text-gray-400 mt-4 border-t pt-3">
                Generated {Calendar.strftime(@ai_generated_at, "%Y-%m-%d %H:%M")} UTC — cached for 24 hours
              </p>
            <% end %>
            <%= if !@ai_analysis and !@ai_loading and @ai_configured do %>
              <p class="text-sm text-gray-500">
                Click "Generate Analysis" to get AI-powered insights from your data.
              </p>
            <% end %>
            <%= if !@ai_configured do %>
              <p class="text-sm text-gray-500">
                Add an AI provider API key in Site Settings to enable AI-powered analysis.
                Supports Anthropic (Claude), OpenAI, and Google (Gemini).
              </p>
            <% end %>
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
            Enum.filter(
              anomalies,
              &(&1.category in ["traffic", "engagement", "sources", "pages"] and
                  &1.severity not in [:high, :medium])
            )

          {"Revenue & Ads", _} ->
            Enum.filter(
              anomalies,
              &(&1.category in ["revenue", "advertising", "retention", "ad traffic"] and
                  &1.severity not in [:high, :medium])
            )

          {"Opportunities", severities} ->
            Enum.filter(
              anomalies,
              &(&1.severity in severities and
                  &1.category not in [
                    "seo",
                    "traffic",
                    "engagement",
                    "sources",
                    "pages",
                    "revenue",
                    "advertising",
                    "retention",
                    "ad traffic"
                  ])
            )

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

  # Simple markdown to HTML — handles headers, bold, lists, paragraphs
  defp render_markdown(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      line = String.trim_trailing(line)

      cond do
        String.starts_with?(line, "## ") ->
          "<h3 class=\"text-base font-semibold text-gray-900 mt-4 mb-2\">#{escape(String.trim_leading(line, "## "))}</h3>"

        String.starts_with?(line, "# ") ->
          "<h2 class=\"text-lg font-bold text-gray-900 mt-4 mb-2\">#{escape(String.trim_leading(line, "# "))}</h2>"

        String.match?(line, ~r/^\d+\.\s/) ->
          "<li class=\"ml-4 text-sm text-gray-700\">#{inline_format(String.replace(line, ~r/^\d+\.\s/, ""))}</li>"

        String.starts_with?(line, "- ") ->
          "<li class=\"ml-4 text-sm text-gray-700\">#{inline_format(String.trim_leading(line, "- "))}</li>"

        line == "" ->
          ""

        true ->
          "<p class=\"text-sm text-gray-700 mb-2\">#{inline_format(line)}</p>"
      end
    end)
    |> Enum.join("\n")
  end

  defp render_markdown(_), do: ""

  defp inline_format(text) do
    text
    |> escape()
    |> String.replace(~r/\*\*(.+?)\*\*/, "<strong>\\1</strong>")
    |> String.replace(~r/\*(.+?)\*/, "<em>\\1</em>")
    |> String.replace(~r/`(.+?)`/, "<code class=\"bg-gray-100 px-1 rounded text-xs\">\\1</code>")
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
