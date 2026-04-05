defmodule Spectabas.Sites.Site do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sites" do
    belongs_to :account, Spectabas.Accounts.Account
    field :name, :string
    field :domain, :string
    field :public_key, :string
    field :timezone, :string, default: "UTC"
    field :retention_days, :integer, default: 365
    field :active, :boolean, default: true
    field :dns_verified, :boolean, default: false
    field :dns_verified_at, :utc_datetime
    field :gdpr_mode, :string, default: "on"
    field :cookie_domain, :string
    field :cross_domain_tracking, :boolean, default: false
    field :cross_domain_sites, {:array, :string}, default: []
    field :ecommerce_enabled, :boolean, default: false
    field :currency, :string, default: "USD"
    field :ip_allowlist, {:array, :string}, default: []
    field :ip_blocklist, {:array, :string}, default: []
    field :native_start_date, :date
    field :import_end_date, :date
    field :ad_credentials_encrypted, :binary
    field :ai_config_encrypted, :binary
    field :intent_config, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a site.
  """
  def changeset(site, attrs) do
    site
    |> cast(attrs, [
      :account_id,
      :name,
      :domain,
      :timezone,
      :retention_days,
      :active,
      :gdpr_mode,
      :cookie_domain,
      :cross_domain_tracking,
      :cross_domain_sites,
      :ecommerce_enabled,
      :currency,
      :ip_allowlist,
      :ip_blocklist,
      :native_start_date,
      :import_end_date,
      :intent_config,
      :ai_config_encrypted
    ])
    |> validate_required([:name, :domain])
    |> validate_length(:name, max: 255)
    |> validate_length(:domain, max: 255)
    |> validate_inclusion(:gdpr_mode, ["on", "off"])
    |> validate_number(:retention_days, greater_than: 0, less_than_or_equal_to: 3650)
    |> validate_length(:currency, is: 3)
    |> unique_constraint(:domain)
    |> unique_constraint(:public_key)
  end

  @doc """
  Generates a random public key for a site (16 bytes, base64url encoded).
  """
  def generate_public_key do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
