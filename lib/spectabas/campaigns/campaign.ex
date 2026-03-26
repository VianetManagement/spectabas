defmodule Spectabas.Campaigns.Campaign do
  @moduledoc """
  Schema for marketing campaigns with UTM parameters.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "campaigns" do
    field :name, :string
    field :utm_source, :string
    field :utm_medium, :string
    field :utm_campaign, :string
    field :utm_term, :string
    field :utm_content, :string
    field :destination_url, :string
    field :active, :boolean, default: true

    belongs_to :site, Spectabas.Sites.Site

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name site_id)a
  @optional_fields ~w(utm_source utm_medium utm_campaign utm_term utm_content destination_url active)a

  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
    |> validate_length(:destination_url, max: 2048)
    |> foreign_key_constraint(:site_id)
  end
end
