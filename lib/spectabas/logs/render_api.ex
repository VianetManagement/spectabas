defmodule Spectabas.Logs.RenderAPI do
  @moduledoc """
  Thin client for Render's REST Logs API. Render's Log Streams require
  a TLS-syslog destination, which needs a Pro+ workspace to expose
  inbound TCP on Render's side and a TLS-cert-bearing receiver on
  ours. The Logs API works on every Render plan including the free
  Hobby tier and is plain outbound HTTPS — much simpler for v1.

      GET https://api.render.com/v1/logs?
        ownerId=tea-...&
        resource=srv-...&
        startTime=2026-05-15T14:00:00Z&
        limit=100

  Authentication: `Authorization: Bearer <api_key>` where `<api_key>`
  is a workspace-level API key created at Account Settings → API
  Keys. Render doesn't offer scoped keys, so the key has full
  workspace access — surface this in the UI when prompting the user.

  Response shape:

      {
        "hasMore": false,
        "nextStartTime": "...",
        "nextEndTime": "...",
        "logs": [
          {
            "id": "log-xxx",
            "timestamp": "2026-05-15T14:00:00.000Z",
            "labels": [{"name": "type", "value": "app"}, ...],
            "message": "..."
          }
        ]
      }
  """

  alias Spectabas.AdIntegrations.{HTTP, Vault}

  require Logger

  @base_url "https://api.render.com/v1"
  @default_limit 100

  @doc """
  Fetch logs for one service starting at `start_time` (ISO 8601 string
  or nil — nil means "from now-1m").

  Returns `{:ok, %{logs: [...], next_start_time: iso8601_or_nil, has_more: bool}}`
  or `{:error, reason}`.
  """
  def list_logs(site, service_id, start_time, opts \\ [])

  def list_logs(_site, nil, _start_time, _opts), do: {:error, :no_service_id}

  def list_logs(site, service_id, start_time, opts) do
    with {:ok, api_key} <- decrypt_api_key(site),
         {:ok, owner_id} <- fetch_owner_id(site) do
      params = [
        ownerId: owner_id,
        resource: service_id,
        limit: opts[:limit] || @default_limit
      ]

      params =
        case start_time do
          nil -> params
          "" -> params
          ts -> Keyword.put(params, :startTime, ts)
        end

      url = "#{@base_url}/logs"

      case HTTP.get(url,
             params: params,
             headers: [{"authorization", "Bearer #{api_key}"}, {"accept", "application/json"}],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: %{"logs" => logs} = body}} ->
          {:ok,
           %{
             logs: logs || [],
             next_start_time: body["nextStartTime"],
             has_more: body["hasMore"] || false
           }}

        {:ok, %{status: 401}} ->
          {:error, :unauthorized}

        {:ok, %{status: 403}} ->
          {:error, :forbidden}

        {:ok, %{status: 404}} ->
          {:error, :not_found}

        {:ok, %{status: 429}} ->
          {:error, :rate_limited}

        {:ok, %{status: status, body: body}} ->
          Logger.warning(
            "[RenderAPI] unexpected status #{status}: #{inspect(body) |> String.slice(0, 200)}"
          )

          {:error, {:unexpected_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Verify that an API key + owner ID combo can list services. Used by
  the Site Settings "Test connection" button.
  """
  def verify_credentials(api_key, owner_id) when is_binary(api_key) and is_binary(owner_id) do
    case HTTP.get("#{@base_url}/services",
           params: [ownerId: owner_id, limit: 1],
           headers: [{"authorization", "Bearer #{api_key}"}, {"accept", "application/json"}],
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: 403}} -> {:error, :forbidden}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decrypt_api_key(%{render_api_key_encrypted: nil}), do: {:error, :no_api_key}
  defp decrypt_api_key(%{render_api_key_encrypted: ""}), do: {:error, :no_api_key}

  defp decrypt_api_key(%{render_api_key_encrypted: ciphertext}) do
    case Vault.decrypt(ciphertext) do
      :error -> {:error, :api_key_decrypt_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  defp decrypt_api_key(_), do: {:error, :no_api_key}

  defp fetch_owner_id(%{render_owner_id: id}) when is_binary(id) and byte_size(id) > 0,
    do: {:ok, id}

  defp fetch_owner_id(_), do: {:error, :no_owner_id}

  @doc """
  Extract the host / instance / type labels from a Render log entry,
  returning a 3-tuple {host, instance, type}. Each is a binary or `""`.
  Labels in Render's response are an array of `{name, value}` maps.
  """
  def label(%{"labels" => labels}, name) when is_list(labels) and is_binary(name) do
    Enum.find_value(labels, "", fn
      %{"name" => ^name, "value" => v} when is_binary(v) -> v
      _ -> false
    end) || ""
  end

  def label(_, _), do: ""
end
