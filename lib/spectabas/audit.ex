defmodule Spectabas.Audit do
  @moduledoc """
  Audit logging for privilege-sensitive actions.
  Automatically redacts fields whose names contain sensitive keywords.
  """

  alias Spectabas.{Repo, Accounts.AuditLog}
  require Logger

  @redacted ~w(password token secret key hash credential)

  @doc """
  Log an audit event with optional metadata map.
  Sensitive fields are automatically stripped from metadata.
  """
  def log(event, metadata \\ %{}) do
    {user_id, meta} =
      case metadata do
        %{user_id: uid} -> {uid, Map.delete(metadata, :user_id)}
        %{"user_id" => uid} -> {uid, Map.delete(metadata, "user_id")}
        _ -> {nil, metadata}
      end

    %AuditLog{}
    |> AuditLog.changeset(%{
      event: to_string(event),
      metadata: sanitize(meta),
      user_id: user_id,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, e} -> Logger.error("[Audit] #{event}: #{inspect(e)}")
    end
  end

  defp sanitize(m) when is_map(m) do
    Map.reject(m, fn {k, _} ->
      key = to_string(k) |> String.downcase()
      Enum.any?(@redacted, &String.contains?(key, &1))
    end)
  end

  defp sanitize(m), do: m
end
