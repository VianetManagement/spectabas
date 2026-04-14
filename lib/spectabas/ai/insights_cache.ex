defmodule Spectabas.AI.InsightsCache do
  use Ecto.Schema
  import Ecto.Query

  schema "ai_insights_cache" do
    field :site_id, :integer
    field :content, :string
    field :provider, :string
    field :model, :string
    field :generated_at, :utc_datetime
  end

  @doc "Get the most recent analysis for a site. Persists indefinitely — user regenerates when they want fresh data."
  def get(site_id) do
    Spectabas.Repo.one(
      from(c in __MODULE__,
        where: c.site_id == ^site_id
      )
    )
  end

  def put(site_id, content, provider, model) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Spectabas.Repo.one(from(c in __MODULE__, where: c.site_id == ^site_id)) do
      nil ->
        %__MODULE__{
          site_id: site_id,
          content: content,
          provider: provider,
          model: model,
          generated_at: now
        }
        |> Spectabas.Repo.insert()

      existing ->
        existing
        |> Ecto.Changeset.change(%{
          content: content,
          provider: provider,
          model: model,
          generated_at: now
        })
        |> Spectabas.Repo.update()
    end
  end
end
