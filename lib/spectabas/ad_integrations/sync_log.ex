defmodule Spectabas.AdIntegrations.SyncLog do
  @moduledoc "Records individual sync events for integrations."

  use Ecto.Schema
  import Ecto.Changeset

  schema "integration_sync_logs" do
    belongs_to :integration, Spectabas.AdIntegrations.AdIntegration
    field :site_id, :integer
    field :platform, :string
    field :event, :string
    field :status, :string, default: "ok"
    field :message, :string
    field :details, :map, default: %{}
    field :duration_ms, :integer

    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:integration_id, :site_id, :platform, :event, :status, :message, :details, :duration_ms])
    |> validate_required([:integration_id, :site_id, :platform, :event, :status])
  end

  @doc "Log a sync event. Returns {:ok, log} or {:error, changeset}."
  def log(integration, event, status, message \\ nil, opts \\ []) do
    %__MODULE__{}
    |> changeset(%{
      integration_id: integration.id,
      site_id: integration.site_id,
      platform: integration.platform,
      event: event,
      status: status,
      message: message,
      details: Keyword.get(opts, :details, %{}),
      duration_ms: Keyword.get(opts, :duration_ms)
    })
    |> Spectabas.Repo.insert()
  end

  @doc "Get recent logs for a site's integrations."
  def recent_for_site(site_id, limit \\ 100) do
    import Ecto.Query

    Spectabas.Repo.all(
      from(l in __MODULE__,
        where: l.site_id == ^site_id,
        order_by: [desc: l.inserted_at],
        limit: ^limit
      )
    )
  end

  @doc "Get recent logs for a specific integration."
  def recent_for_integration(integration_id, limit \\ 50) do
    import Ecto.Query

    Spectabas.Repo.all(
      from(l in __MODULE__,
        where: l.integration_id == ^integration_id,
        order_by: [desc: l.inserted_at],
        limit: ^limit
      )
    )
  end

  @doc "Delete logs older than N days."
  def cleanup(days \\ 30) do
    import Ecto.Query

    cutoff = DateTime.add(DateTime.utc_now(), -days * 86400, :second)

    Spectabas.Repo.delete_all(
      from(l in __MODULE__, where: l.inserted_at < ^cutoff)
    )
  end
end
