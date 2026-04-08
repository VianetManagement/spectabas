defmodule Spectabas.AI.Completion do
  @moduledoc """
  Unified AI completion interface. Routes to Anthropic, OpenAI, or Google
  based on site configuration.
  """

  require Logger

  @timeout 60_000

  @doc """
  Generate a completion from the configured AI provider.
  Returns {:ok, text} or {:error, reason}.
  """
  def generate(site, system_prompt, user_prompt) do
    case Spectabas.AI.Config.credentials(site) do
      {nil, _, _} -> {:error, "No AI provider configured"}
      {"none", _, _} -> {:error, "AI disabled"}
      {_, nil, _} -> {:error, "No API key configured"}
      {provider, api_key, model} -> call(provider, api_key, model, system_prompt, user_prompt)
    end
  end

  defp call("anthropic", api_key, model, system_prompt, user_prompt) do
    body =
      Jason.encode!(%{
        model: model,
        max_tokens: 2048,
        system: system_prompt,
        messages: [%{role: "user", content: user_prompt}]
      })

    case Req.post("https://api.anthropic.com/v1/messages",
           body: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        msg =
          if is_map(body),
            do: get_in(body, ["error", "message"]) || "HTTP #{status}",
            else: "HTTP #{status}"

        Logger.warning("[AI:anthropic] #{msg}")
        {:error, msg}

      {:error, reason} ->
        Logger.warning("[AI:anthropic] #{inspect(reason)}")
        {:error, "API request failed"}
    end
  end

  defp call("openai", api_key, model, system_prompt, user_prompt) do
    body =
      Jason.encode!(%{
        model: model,
        max_tokens: 2048,
        messages: [
          %{role: "system", content: system_prompt},
          %{role: "user", content: user_prompt}
        ]
      })

    case Req.post("https://api.openai.com/v1/chat/completions",
           body: body,
           headers: [
             {"authorization", "Bearer #{api_key}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: @timeout
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        msg =
          if is_map(body),
            do: get_in(body, ["error", "message"]) || "HTTP #{status}",
            else: "HTTP #{status}"

        Logger.warning("[AI:openai] #{msg}")
        {:error, msg}

      {:error, reason} ->
        Logger.warning("[AI:openai] #{inspect(reason)}")
        {:error, "API request failed"}
    end
  end

  defp call("google", api_key, model, system_prompt, user_prompt) do
    body =
      Jason.encode!(%{
        contents: [%{parts: [%{text: user_prompt}]}],
        systemInstruction: %{parts: [%{text: system_prompt}]},
        generationConfig: %{maxOutputTokens: 2048}
      })

    case Req.post(
           "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: @timeout
         ) do
      {:ok,
       %{
         status: 200,
         body: %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]}
       }} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        msg =
          if is_map(body),
            do: get_in(body, ["error", "message"]) || "HTTP #{status}",
            else: "HTTP #{status}"

        Logger.warning("[AI:google] #{msg}")
        {:error, msg}

      {:error, reason} ->
        Logger.warning("[AI:google] #{inspect(reason)}")
        {:error, "API request failed"}
    end
  end

  defp call(provider, _, _, _, _) do
    {:error, "Unknown AI provider: #{provider}"}
  end
end
