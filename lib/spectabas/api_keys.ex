defmodule Spectabas.APIKeys do
  @moduledoc """
  API key generation, verification, and lifecycle management.
  Key format: sab_live_ + 32 random bytes base64url encoded.
  Only the SHA-256 hash is stored; the plaintext key is returned once at creation.
  """

  import Ecto.Query, warn: false
  alias Spectabas.{Repo, Audit}
  alias Spectabas.Accounts.APIKey

  @prefix "sab_live_"

  @doc """
  Generate a new API key for a user. Returns `{:ok, plaintext_key, api_key}`.
  The plaintext key is only available at creation time.
  """
  def generate(user, name) when is_binary(name) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    plaintext = @prefix <> raw
    key_hash = hash_key(plaintext)
    key_prefix = String.slice(plaintext, 0, 12)

    attrs = %{
      user_id: user.id,
      name: name,
      key_hash: key_hash,
      key_prefix: key_prefix
    }

    %APIKey{}
    |> APIKey.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, api_key} ->
        Audit.log("api_key.created", %{user_id: user.id, key_prefix: key_prefix, name: name})
        {:ok, plaintext, api_key}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Verify an API key by hashing it and looking it up.
  Returns `{:ok, api_key}` with preloaded user or `{:error, :invalid}`.
  """
  def verify(plaintext_key) when is_binary(plaintext_key) do
    key_hash = hash_key(plaintext_key)

    case Repo.one(from k in APIKey, where: k.key_hash == ^key_hash and is_nil(k.revoked_at)) do
      nil -> {:error, :invalid}
      api_key -> {:ok, api_key}
    end
  end

  @doc """
  Asynchronously update the last_used_at timestamp for an API key.
  """
  def touch(%APIKey{} = api_key) do
    Task.start(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      api_key
      |> Ecto.Changeset.change(last_used_at: now)
      |> Repo.update()
    end)

    :ok
  end

  @doc """
  Revoke an API key. Returns `{:ok, api_key}` or `{:error, changeset}`.
  """
  def revoke(admin, %APIKey{} = api_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    api_key
    |> Ecto.Changeset.change(revoked_at: now)
    |> Repo.update()
    |> case do
      {:ok, revoked} ->
        Audit.log("api_key.revoked", %{
          revoked_by: admin.id,
          key_prefix: api_key.key_prefix,
          user_id: api_key.user_id
        })

        {:ok, revoked}

      error ->
        error
    end
  end

  @doc """
  List all API keys for a user.
  """
  def list_user_keys(user) do
    Repo.all(from k in APIKey, where: k.user_id == ^user.id, order_by: [desc: k.inserted_at])
  end

  defp hash_key(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end
end
