defmodule Spectabas.Notifications.Slack do
  @moduledoc """
  Sends notifications to Slack via incoming webhook.
  Set SLACK_WEBHOOK_URL env var to enable. If not set, messages are silently dropped.
  """

  require Logger

  alias Spectabas.AdIntegrations.HTTP

  @doc "Send a simple text message to Slack."
  def notify(message) when is_binary(message) do
    case webhook_url() do
      nil -> :ok
      url -> post(url, %{text: message})
    end
  end

  @doc "Send a formatted message with blocks to Slack."
  def notify(message, fields) when is_binary(message) and is_list(fields) do
    case webhook_url() do
      nil ->
        :ok

      url ->
        field_blocks =
          Enum.map(fields, fn {label, value} ->
            %{type: "mrkdwn", text: "*#{label}*\n#{value}"}
          end)

        payload = %{
          blocks: [
            %{
              type: "section",
              text: %{type: "mrkdwn", text: message}
            },
            %{
              type: "section",
              fields: field_blocks
            }
          ]
        }

        post(url, payload)
    end
  end

  @doc "Send a sync failure alert."
  def sync_failed(worker_name, site_name, error) do
    notify(
      ":warning: *Sync Failed* — #{worker_name}",
      [
        {"Site", site_name},
        {"Error", "`#{String.slice(to_string(error), 0, 200)}`"},
        {"Action", "Check Settings > Integrations or click Sync Now"}
      ]
    )
  end

  defp post(url, payload) do
    case HTTP.post(url, json: payload) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[Slack] HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}")
        :ok

      {:error, reason} ->
        Logger.warning("[Slack] Failed: #{inspect(reason) |> String.slice(0, 200)}")
        :ok
    end
  end

  defp webhook_url do
    case Application.get_env(:spectabas, :slack_webhook_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end
end
