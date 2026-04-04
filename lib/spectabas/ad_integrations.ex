defmodule Spectabas.AdIntegrations do
  @moduledoc "Context for managing ad platform integrations (Google Ads, Bing, Meta)."

  import Ecto.Query
  alias Spectabas.Repo
  alias Spectabas.AdIntegrations.{AdIntegration, Vault}

  def list_for_site(site_id) do
    from(a in AdIntegration, where: a.site_id == ^site_id, order_by: [asc: a.platform])
    |> Repo.all()
  end

  def list_active do
    from(a in AdIntegration, where: a.status == "active")
    |> Repo.all()
  end

  def get!(id), do: Repo.get!(AdIntegration, id)

  alias Spectabas.Audit

  def connect(site_id, platform, tokens) do
    attrs = %{
      site_id: site_id,
      platform: platform,
      account_id: tokens[:account_id] || "",
      account_name: tokens[:account_name] || "",
      access_token_encrypted: Vault.encrypt(tokens.access_token),
      refresh_token_encrypted: Vault.encrypt(tokens.refresh_token),
      token_expires_at: tokens[:expires_at],
      scopes: tokens[:scopes] || [],
      extra: tokens[:extra] || %{},
      status: "active"
    }

    result =
      %AdIntegration{}
      |> AdIntegration.changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [
             :access_token_encrypted,
             :refresh_token_encrypted,
             :token_expires_at,
             :status,
             :extra,
             :updated_at
           ]},
        conflict_target: [:site_id, :platform, :account_id]
      )

    case result do
      {:ok, integration} ->
        Audit.log("ad_integration.connected", %{
          site_id: site_id,
          platform: platform,
          account_id: tokens[:account_id] || ""
        })

        {:ok, integration}

      error ->
        error
    end
  end

  def disconnect(integration) do
    # Use a dummy encrypted value (single null byte) — validate_required needs non-empty binary
    tombstone = Vault.encrypt("revoked")

    result =
      integration
      |> AdIntegration.changeset(%{
        status: "revoked",
        access_token_encrypted: tombstone,
        refresh_token_encrypted: tombstone,
        last_error: nil
      })
      |> Repo.update()

    case result do
      {:ok, updated} ->
        Audit.log("ad_integration.disconnected", %{
          site_id: integration.site_id,
          platform: integration.platform,
          account_id: integration.account_id || ""
        })

        {:ok, updated}

      error ->
        error
    end
  end

  def update_tokens(integration, access_token, refresh_token, expires_at) do
    integration
    |> AdIntegration.changeset(%{
      access_token_encrypted: Vault.encrypt(access_token),
      refresh_token_encrypted: Vault.encrypt(refresh_token || ""),
      token_expires_at: expires_at,
      status: "active"
    })
    |> Repo.update()
  end

  def mark_synced(integration) do
    integration
    |> AdIntegration.changeset(%{
      last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_error: nil
    })
    |> Repo.update()
  end

  def mark_error(integration, error) do
    # Keep status as "active" so the cron continues to retry.
    # Only record the error message — don't change status.
    integration
    |> AdIntegration.changeset(%{
      last_error: String.slice(to_string(error), 0, 500)
    })
    |> Repo.update()
  end

  def decrypt_access_token(integration) do
    Vault.decrypt(integration.access_token_encrypted)
  end

  def decrypt_refresh_token(integration) do
    Vault.decrypt(integration.refresh_token_encrypted)
  end

  def token_expired?(integration) do
    case integration.token_expires_at do
      nil -> false
      expires_at -> DateTime.compare(expires_at, DateTime.utc_now()) == :lt
    end
  end

  @doc """
  Check if enough time has elapsed since last sync based on the integration's
  configured frequency. Returns true if sync should proceed.
  Default frequencies: stripe/braintree = 15 min, ad platforms = 360 min (6h).
  """
  def should_sync?(integration) do
    default_freq =
      case integration.platform do
        p when p in ["stripe", "braintree"] -> 15
        _ -> 360
      end

    freq_minutes = (integration.extra || %{})["sync_frequency_minutes"] || default_freq

    case integration.last_synced_at do
      nil -> true
      last -> DateTime.diff(DateTime.utc_now(), last, :minute) >= freq_minutes
    end
  end

  @doc "Get the sync frequency in minutes for an integration."
  def sync_frequency(integration) do
    default =
      case integration.platform do
        p when p in ["stripe", "braintree"] -> 15
        _ -> 360
      end

    (integration.extra || %{})["sync_frequency_minutes"] || default
  end

  @doc "Update the sync frequency for an integration."
  def update_sync_frequency(integration, minutes) when is_integer(minutes) and minutes >= 5 do
    extra = Map.put(integration.extra || %{}, "sync_frequency_minutes", minutes)

    integration
    |> AdIntegration.changeset(%{extra: extra})
    |> Repo.update()
  end
end
