defmodule Spectabas.Campaigns do
  @moduledoc """
  Context for managing marketing campaigns and building UTM-tagged URLs.
  """

  import Ecto.Query, warn: false

  alias Spectabas.Repo
  alias Spectabas.Campaigns.Campaign

  @doc """
  Create a campaign for a site.
  """
  def create_campaign(site, attrs) do
    %Campaign{}
    |> Campaign.changeset(Map.put(attrs, :site_id, site.id))
    |> Repo.insert()
  end

  @doc """
  List all campaigns for a site.
  """
  def list_campaigns(site) do
    Repo.all(
      from(c in Campaign,
        where: c.site_id == ^site.id,
        order_by: [desc: c.inserted_at]
      )
    )
  end

  @doc """
  Build a full URL with UTM parameters from a campaign.
  Returns the destination URL with query parameters appended.
  """
  def build_url(%Campaign{destination_url: nil}), do: {:error, :no_destination_url}

  def build_url(%Campaign{destination_url: url} = campaign) do
    uri = URI.parse(url)

    existing_params = URI.decode_query(uri.query || "")

    utm_params =
      [
        {"utm_source", campaign.utm_source},
        {"utm_medium", campaign.utm_medium},
        {"utm_campaign", campaign.utm_campaign},
        {"utm_term", campaign.utm_term},
        {"utm_content", campaign.utm_content}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    merged = Map.merge(existing_params, utm_params)

    result =
      %{uri | query: URI.encode_query(merged)}
      |> URI.to_string()

    {:ok, result}
  end
end
