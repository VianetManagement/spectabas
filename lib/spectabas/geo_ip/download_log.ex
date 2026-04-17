defmodule Spectabas.GeoIP.DownloadLog do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Spectabas.Repo

  schema "geoip_downloads" do
    field :database_name, :string
    field :status, :string, default: "pending"
    field :file_size, :integer
    field :error_message, :string
    field :duration_ms, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:database_name, :status, :file_size, :error_message, :duration_ms])
    |> validate_required([:database_name, :status])
    |> validate_inclusion(:status, ["pending", "success", "error"])
  end

  def log_download(database_name, status, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      database_name: database_name,
      status: status,
      file_size: Keyword.get(opts, :file_size),
      error_message: Keyword.get(opts, :error_message),
      duration_ms: Keyword.get(opts, :duration_ms)
    })
    |> Repo.insert()
  end

  def latest_per_database do
    subquery =
      from(d in __MODULE__,
        select: %{database_name: d.database_name, max_id: max(d.id)},
        group_by: d.database_name
      )

    from(d in __MODULE__,
      join: s in subquery(subquery),
      on: d.id == s.max_id,
      order_by: [asc: d.database_name]
    )
    |> Repo.all()
  end

  def recent(limit \\ 50) do
    from(d in __MODULE__,
      order_by: [desc: d.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
