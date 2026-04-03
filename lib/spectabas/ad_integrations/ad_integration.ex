defmodule Spectabas.AdIntegrations.AdIntegration do
  use Ecto.Schema
  import Ecto.Changeset

  @platforms ~w(google_ads bing_ads meta_ads stripe braintree)

  schema "ad_integrations" do
    belongs_to :site, Spectabas.Sites.Site

    field :platform, :string
    field :account_id, :string
    field :account_name, :string
    field :access_token_encrypted, :binary
    field :refresh_token_encrypted, :binary
    field :token_expires_at, :utc_datetime
    field :scopes, {:array, :string}, default: []
    field :extra, :map, default: %{}
    field :status, :string, default: "active"
    field :last_synced_at, :utc_datetime
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  def platforms, do: @platforms

  def changeset(integration, attrs) do
    integration
    |> cast(attrs, [
      :site_id,
      :platform,
      :account_id,
      :account_name,
      :access_token_encrypted,
      :refresh_token_encrypted,
      :token_expires_at,
      :scopes,
      :extra,
      :status,
      :last_synced_at,
      :last_error
    ])
    |> validate_required([:site_id, :platform, :access_token_encrypted, :refresh_token_encrypted])
    |> validate_inclusion(:platform, @platforms)
    |> unique_constraint([:site_id, :platform, :account_id])
  end
end
