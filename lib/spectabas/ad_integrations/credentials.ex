defmodule Spectabas.AdIntegrations.Credentials do
  @moduledoc """
  Read/write ad platform credentials (client_id, client_secret, developer_token)
  stored as an encrypted JSON blob on the sites table.

  Structure:
  %{
    "google_ads" => %{"client_id" => "...", "client_secret" => "...", "developer_token" => "..."},
    "bing_ads" => %{"client_id" => "...", "client_secret" => "...", "developer_token" => "..."},
    "meta_ads" => %{"app_id" => "...", "app_secret" => "..."}
  }
  """

  alias Spectabas.AdIntegrations.Vault

  @doc "Get credentials for a specific platform from the site's encrypted blob."
  def get_for_platform(site, platform) do
    case decrypt_all(site) do
      %{^platform => creds} when is_map(creds) -> creds
      _ -> %{}
    end
  end

  @doc "Get all platform credentials for a site."
  def get_all(site) do
    decrypt_all(site)
  end

  @doc "Save credentials for a platform. Merges with existing credentials for other platforms."
  def save(site, platform, creds) when is_map(creds) do
    all = decrypt_all(site)
    updated = Map.put(all, platform, creds)
    encrypted = Vault.encrypt(Jason.encode!(updated))

    site
    |> Ecto.Changeset.change(%{ad_credentials_encrypted: encrypted})
    |> Spectabas.Repo.update()
  end

  @doc "Delete credentials for a platform."
  def delete(site, platform) do
    all = decrypt_all(site)
    updated = Map.delete(all, platform)
    encrypted = Vault.encrypt(Jason.encode!(updated))

    site
    |> Ecto.Changeset.change(%{ad_credentials_encrypted: encrypted})
    |> Spectabas.Repo.update()
  end

  @doc "Check if credentials are configured for a platform."
  def configured?(site, "google_ads") do
    creds = get_for_platform(site, "google_ads")
    creds["client_id"] not in [nil, ""] and creds["client_secret"] not in [nil, ""]
  end

  def configured?(site, "bing_ads") do
    creds = get_for_platform(site, "bing_ads")
    creds["client_id"] not in [nil, ""] and creds["client_secret"] not in [nil, ""]
  end

  def configured?(site, "meta_ads") do
    creds = get_for_platform(site, "meta_ads")
    creds["app_id"] not in [nil, ""] and creds["app_secret"] not in [nil, ""]
  end

  def configured?(site, "stripe") do
    creds = get_for_platform(site, "stripe")
    creds["api_key"] not in [nil, ""]
  end

  def configured?(site, "braintree") do
    creds = get_for_platform(site, "braintree")

    creds["merchant_id"] not in [nil, ""] and
      creds["public_key"] not in [nil, ""] and
      creds["private_key"] not in [nil, ""]
  end

  def configured?(site, "google_search_console") do
    creds = get_for_platform(site, "google_search_console")
    creds["client_id"] not in [nil, ""] and creds["client_secret"] not in [nil, ""]
  end

  def configured?(site, "bing_webmaster") do
    creds = get_for_platform(site, "bing_webmaster")
    creds["api_key"] not in [nil, ""]
  end

  def configured?(_, _), do: false

  defp decrypt_all(%{ad_credentials_encrypted: nil}), do: %{}
  defp decrypt_all(%{ad_credentials_encrypted: <<>>}), do: %{}

  defp decrypt_all(%{ad_credentials_encrypted: encrypted}) when is_binary(encrypted) do
    case Vault.decrypt(encrypted) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp decrypt_all(_), do: %{}
end
