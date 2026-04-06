defmodule Spectabas.AI.Config do
  @moduledoc """
  Read/write AI provider configuration stored as encrypted JSON on sites table.

  Structure:
  %{
    "provider" => "anthropic" | "openai" | "google" | "none",
    "api_key" => "sk-...",
    "model" => "claude-haiku-4-5-20251001" | "gpt-4o-mini" | "gemini-2.0-flash" | etc.
  }
  """

  alias Spectabas.AdIntegrations.Vault

  @providers %{
    "anthropic" => %{
      label: "Anthropic (Claude)",
      models: [
        {"claude-haiku-4-5-20251001", "Claude Haiku 4.5 (fast, cheap)"},
        {"claude-sonnet-4-6", "Claude Sonnet 4.6 (balanced)"}
      ],
      default_model: "claude-haiku-4-5-20251001"
    },
    "openai" => %{
      label: "OpenAI",
      models: [
        {"gpt-4o-mini", "GPT-4o Mini (fast, cheap)"},
        {"gpt-4o", "GPT-4o (balanced)"}
      ],
      default_model: "gpt-4o-mini"
    },
    "google" => %{
      label: "Google AI (Gemini)",
      models: [
        {"gemini-2.0-flash", "Gemini 2.0 Flash (fast, cheap)"},
        {"gemini-2.5-pro", "Gemini 2.5 Pro (balanced)"}
      ],
      default_model: "gemini-2.0-flash"
    }
  }

  def providers, do: @providers

  @doc "Get AI config for a site. Returns map or empty map."
  def get(site) do
    case site.ai_config_encrypted do
      nil -> %{}
      <<>> -> %{}
      encrypted ->
        case Vault.decrypt(encrypted) do
          json when is_binary(json) -> Jason.decode!(json)
          _ -> %{}
        end
    end
  end

  @doc "Save AI config for a site."
  def save(site, config) when is_map(config) do
    encrypted = Vault.encrypt(Jason.encode!(config))

    site
    |> Ecto.Changeset.change(%{ai_config_encrypted: encrypted})
    |> Spectabas.Repo.update()
  end

  @doc "Check if a site has AI configured."
  def configured?(site) do
    config = get(site)
    config["provider"] not in [nil, "", "none"] and config["api_key"] not in [nil, ""]
  end

  @doc "Get the provider, api_key, and model for a site."
  def credentials(site) do
    config = get(site)
    provider = config["provider"]
    api_key = config["api_key"]
    model = config["model"] || default_model(provider)
    {provider, api_key, model}
  end

  defp default_model(provider) do
    case @providers[provider] do
      %{default_model: m} -> m
      _ -> nil
    end
  end
end
