defmodule Spectabas.AdIntegrations.Vault do
  @moduledoc "AES-256-GCM encryption for ad platform OAuth tokens."

  @aad "spectabas_ad_tokens"

  def encrypt(plaintext) when is_binary(plaintext) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)
    iv <> tag <> ciphertext
  end

  def decrypt(data) when is_binary(data) and byte_size(data) > 28 do
    key = derive_key()
    <<iv::binary-12, tag::binary-16, ciphertext::binary>> = data
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false)
  rescue
    _ -> :error
  end

  def decrypt(_), do: :error

  defp derive_key do
    secret = Application.get_env(:spectabas, SpectabasWeb.Endpoint)[:secret_key_base]
    :crypto.hash(:sha256, secret)
  end
end
