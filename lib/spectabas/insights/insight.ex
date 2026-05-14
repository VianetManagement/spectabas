defmodule Spectabas.Insights.Insight do
  use Ecto.Schema
  import Ecto.Changeset

  alias Spectabas.Insights

  schema "insights" do
    field :site_id, :id
    field :kind, :string
    field :severity, :string, default: "info"
    field :title, :string
    field :body, :string
    field :explanation, :string
    field :data, :map, default: %{}
    field :dedupe_key, :string

    timestamps()
  end

  @required ~w(site_id kind title dedupe_key)a
  @optional ~w(severity body explanation data)a

  def changeset(insight, attrs) do
    insight
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kind, Insights.valid_kinds())
    |> validate_inclusion(:severity, Insights.valid_severities())
    |> validate_length(:title, max: 255)
  end
end
