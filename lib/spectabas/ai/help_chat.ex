defmodule Spectabas.AI.HelpChat do
  @preamble """
  You are a friendly help assistant for Spectabas, a privacy-first web analytics platform. Answer questions about features, setup, and best practices. Be concise — 2-4 sentences for simple questions, more for complex ones. Use markdown for formatting.

  If you don't know the answer, say so and suggest checking the Docs page (/docs) or contacting support.

  Below is the complete, up-to-date documentation for the platform:

  """

  def generate(messages) do
    api_key = Application.get_env(:spectabas, :help_ai_api_key)

    if is_nil(api_key) or api_key == "" do
      {:error, :not_configured}
    else
      call_anthropic(api_key, messages)
    end
  end

  def configured? do
    key = Application.get_env(:spectabas, :help_ai_api_key)
    is_binary(key) and key != ""
  end

  defp system_prompt do
    docs =
      SpectabasWeb.DocsLive.sections()
      |> Enum.map_join("\n\n", fn %{category: cat, items: items} ->
        header = "# #{cat}\n"

        body =
          Enum.map_join(items, "\n\n", fn %{title: title, body: body} ->
            "## #{title}\n#{String.trim(body)}"
          end)

        header <> body
      end)

    @preamble <> docs
  end

  defp call_anthropic(api_key, messages) do
    api_messages =
      Enum.map(messages, fn %{role: role, content: content} ->
        %{"role" => to_string(role), "content" => content}
      end)

    body = %{
      "model" => "claude-haiku-4-5-20251001",
      "system" => system_prompt(),
      "messages" => api_messages,
      "max_tokens" => 1024
    }

    case Req.post("https://api.anthropic.com/v1/messages",
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
           ],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, "API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end
end
