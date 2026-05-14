defmodule SpectabasWeb.InsightCard do
  @moduledoc """
  Shared insight rendering used on the Dashboard overview and the full
  /dashboard/sites/:id/insights feed. Stateless function component —
  parent owns dismiss + drill-down.
  """
  use Phoenix.Component

  attr :insight, :map, required: true
  attr :compact, :boolean, default: false
  attr :dismiss_event, :string, default: "dismiss_insight"

  def insight_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border bg-white shadow-sm overflow-hidden",
      severity_border(@insight.severity)
    ]}>
      <div class="px-4 py-3 flex items-start gap-3">
        <div class={[
          "shrink-0 w-7 h-7 rounded flex items-center justify-center text-xs font-bold",
          severity_badge(@insight.severity)
        ]}>
          {kind_icon(@insight.kind)}
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex items-baseline justify-between gap-3">
            <h4 class="text-sm font-semibold text-gray-900 truncate">
              {@insight.title}
            </h4>
            <span class="text-xs text-gray-400 shrink-0">
              {relative_time(@insight.inserted_at)}
            </span>
          </div>
          <p :if={@insight.body} class="text-xs text-gray-600 mt-1">
            {@insight.body}
          </p>
          <div
            :if={!@compact && @insight.explanation}
            class="mt-2 p-2 rounded bg-indigo-50/40 border border-indigo-100"
          >
            <p class="text-xs text-indigo-900 leading-relaxed">
              <span class="font-medium text-indigo-700">AI:</span> {@insight.explanation}
            </p>
          </div>
          <div
            :if={
              !@compact && is_nil(@insight.explanation) &&
                String.starts_with?(@insight.kind, "anomaly_")
            }
            class="mt-2 text-xs text-gray-400 italic"
          >
            Analyzing…
          </div>
        </div>
        <button
          type="button"
          phx-click={@dismiss_event}
          phx-value-id={@insight.id}
          class="shrink-0 text-gray-300 hover:text-gray-600 px-2 py-0.5 text-xs"
          title="Dismiss"
        >
          ✕
        </button>
      </div>
    </div>
    """
  end

  defp severity_border("warning"), do: "border-red-200"
  defp severity_border("notice"), do: "border-amber-200"
  defp severity_border(_), do: "border-gray-200"

  defp severity_badge("warning"), do: "bg-red-100 text-red-700"
  defp severity_badge("notice"), do: "bg-amber-100 text-amber-700"
  defp severity_badge(_), do: "bg-gray-100 text-gray-600"

  defp kind_icon("anomaly_spike"), do: "↑"
  defp kind_icon("anomaly_drop"), do: "↓"
  defp kind_icon("goal_pace"), do: "◉"
  defp kind_icon("ai_weekly_summary"), do: "✦"
  defp kind_icon("conversion_milestone"), do: "★"
  defp kind_icon(_), do: "•"

  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = dt) do
    secs = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      secs < 60 -> "just now"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp relative_time(%NaiveDateTime{} = ndt) do
    case DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt} -> relative_time(dt)
      _ -> ""
    end
  end
end
