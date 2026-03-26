defmodule Spectabas.Accounts.TOTP do
  @moduledoc """
  TOTP (Time-based One-Time Password) functions using NimbleTOTP.
  Secrets are encrypted at rest using a key derived from SECRET_KEY_BASE.
  """

  alias Spectabas.{Repo, Audit}

  @doc """
  Generate a new random TOTP secret (20 bytes).
  """
  def generate_secret do
    NimbleTOTP.secret()
  end

  @doc """
  Set up TOTP for a user. Stores the encrypted secret but does NOT enable TOTP yet.
  The user must verify a code via `verify_and_enable/2` first.
  Returns `{:ok, user}` with the updated user (totp_secret set, totp_enabled still false).
  """
  def setup(user, label \\ "Spectabas") do
    secret = generate_secret()
    encrypted = encrypt_secret(secret)

    uri =
      NimbleTOTP.otpauth_uri("#{label}:#{user.email}", secret, issuer: "Spectabas")

    user
    |> Ecto.Changeset.change(totp_secret: encrypted, totp_enabled: false)
    |> Repo.update()
    |> case do
      {:ok, updated_user} -> {:ok, updated_user, uri}
      error -> error
    end
  end

  @doc """
  Verify a TOTP code and enable TOTP for the user.
  Should only be called during initial setup to confirm the user's authenticator is working.
  """
  def verify_and_enable(user, code) when is_binary(code) do
    secret = decrypt_secret(user.totp_secret)

    if NimbleTOTP.valid?(secret, code) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      user
      |> Ecto.Changeset.change(totp_enabled: true, totp_enabled_at: now)
      |> Repo.update()
      |> case do
        {:ok, updated_user} ->
          Audit.log("totp.enabled", %{user_id: user.id})
          {:ok, updated_user}

        error ->
          error
      end
    else
      {:error, :invalid_code}
    end
  end

  @doc """
  Verify a TOTP code against a user's stored secret.
  Returns `:ok` or `{:error, :invalid_code}`.
  """
  def verify(user, code) when is_binary(code) do
    if user.totp_enabled && user.totp_secret do
      secret = decrypt_secret(user.totp_secret)

      if NimbleTOTP.valid?(secret, code) do
        :ok
      else
        {:error, :invalid_code}
      end
    else
      {:error, :totp_not_enabled}
    end
  end

  @doc """
  Disable TOTP for a user. Requires an admin user for authorization.
  """
  def disable(admin, user) do
    user
    |> Ecto.Changeset.change(totp_secret: nil, totp_enabled: false, totp_enabled_at: nil)
    |> Repo.update()
    |> case do
      {:ok, updated_user} ->
        Audit.log("totp.disabled", %{user_id: user.id, disabled_by: admin.id})
        {:ok, updated_user}

      error ->
        error
    end
  end

  # Encryption helpers using AES-256-GCM derived from SECRET_KEY_BASE

  defp encryption_key do
    secret_key_base =
      Application.get_env(:spectabas, SpectabasWeb.Endpoint)[:secret_key_base] ||
        raise "SECRET_KEY_BASE not configured"

    :crypto.hash(:sha256, secret_key_base)
  end

  defp encrypt_secret(secret) when is_binary(secret) do
    key = encryption_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, secret, "", true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt_secret(encrypted) when is_binary(encrypted) do
    key = encryption_key()
    decoded = Base.decode64!(encrypted)
    <<iv::binary-12, tag::binary-16, ciphertext::binary>> = decoded
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false)
  end
end
