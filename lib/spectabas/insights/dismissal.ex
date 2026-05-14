defmodule Spectabas.Insights.Dismissal do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "insight_dismissals" do
    field :insight_id, :id
    field :user_id, :id

    timestamps(updated_at: false)
  end

  @required ~w(insight_id user_id)a

  def changeset(dismissal, attrs) do
    dismissal
    |> cast(attrs, @required)
    |> validate_required(@required)
  end
end
