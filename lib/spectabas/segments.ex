defmodule Spectabas.Segments do
  @moduledoc "Context for saved segment filter presets."

  import Ecto.Query
  alias Spectabas.Repo
  alias Spectabas.Analytics.SavedSegment

  @doc "List saved segments for a user on a specific site."
  def list_saved_segments(user, site) do
    from(s in SavedSegment,
      where: s.user_id == ^user.id and s.site_id == ^site.id,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc "Save a new segment preset."
  def save_segment(user, site, name, filters) do
    %SavedSegment{}
    |> SavedSegment.changeset(%{
      user_id: user.id,
      site_id: site.id,
      name: name,
      filters: filters
    })
    |> Repo.insert()
  end

  @doc "Delete a saved segment (only if owned by the given user)."
  def delete_segment(user, segment_id) do
    case Repo.get(SavedSegment, segment_id) do
      nil ->
        {:error, :not_found}

      %SavedSegment{user_id: uid} = segment when uid == user.id ->
        Repo.delete(segment)

      _ ->
        {:error, :unauthorized}
    end
  end

  @doc "Get a saved segment by ID, scoped to the given user and site."
  def get_segment!(id, user, site) do
    Repo.get_by!(SavedSegment, id: id, user_id: user.id, site_id: site.id)
  end
end
