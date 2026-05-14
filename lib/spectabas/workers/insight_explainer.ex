defmodule Spectabas.Workers.InsightExplainer do
  @moduledoc """
  Async per-insight Anthropic Haiku call. Pulls the insight's structured
  context (which metric, what changed, by how much), asks the model for
  a one-paragraph plain-English explanation that contextualizes the
  numbers, and writes back to `insights.explanation`.

  Runs on the default queue with a short timeout — Haiku averages 1-2s
  for prompts this small. Uses the platform-level `HELP_AI_API_KEY` env
  var (same as the help chatbot), not per-site AI config: insight
  explanations are a Spectabas-provided feature, not a customer-billed
  AI call.

  Failure is logged and swallowed — an empty `explanation` field just
  means the UI shows the structured `body` without the AI narrative.
  """

  use Oban.Worker, queue: :default, max_attempts: 2

  require Logger

  alias Spectabas.{Insights, Repo}
  alias Spectabas.Insights.Insight

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"insight_id" => insight_id}}) do
    case Repo.get(Insight, insight_id) do
      nil ->
        :ok

      %Insight{} = insight ->
        case explain(insight) do
          {:ok, text} ->
            Insights.set_explanation(insight, text)

          {:error, reason} ->
            Logger.warning(
              "[InsightExplainer] id=#{insight.id} failed: #{inspect(reason) |> String.slice(0, 200)}"
            )

            :ok
        end
    end
  end

  defp explain(%Insight{} = insight) do
    api_key = Application.get_env(:spectabas, :help_ai_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :not_configured}
    else
      call_anthropic(api_key, insight)
    end
  end

  defp call_anthropic(api_key, %Insight{} = insight) do
    body = %{
      "model" => "claude-haiku-4-5-20251001",
      "system" => system_prompt(),
      "messages" => [%{"role" => "user", "content" => user_prompt(insight)}],
      "max_tokens" => 350
    }

    case Req.post("https://api.anthropic.com/v1/messages",
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 25_000
         ) do
      {:ok, %{status: 200, body: response}} ->
        extract_text(response)

      {:ok, %{status: s, body: b}} ->
        {:error, "anthropic returned #{s}: #{inspect(b) |> String.slice(0, 200)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_text(%{"content" => [%{"text" => text} | _]}) when is_binary(text),
    do: {:ok, String.trim(text)}

  defp extract_text(other), do: {:error, "unexpected response shape: #{inspect(other)}"}

  defp system_prompt do
    """
    You explain web analytics anomalies in plain English to a site owner.

    Rules:
    - 2-3 short sentences. Max ~80 words. No preamble, no lists, no headers.
    - Quantify the change ("traffic dropped 35%, from 800 to 520 pageviews").
    - Suggest the single most likely cause in plain language. Hedge appropriately ("often caused by", "could be").
    - Suggest one concrete next step at the end ("check your campaign URLs", "verify Stripe webhooks are firing").
    - No marketing fluff. Don't say "great", "amazing", "stunning". Write like a helpful coworker.
    """
  end

  defp user_prompt(%Insight{} = insight) do
    data = insight.data || %{}

    """
    Anomaly title: #{insight.title}
    Body: #{insight.body}

    Numbers:
      category: #{data["category"]}
      metric: #{data["metric"]}
      current: #{data["current"]}
      previous: #{data["previous"]}
      change_pct: #{data["change_pct"]}

    Suggested action from the rules engine: #{data["suggested_action"]}

    Write the explanation now.
    """
  end
end
