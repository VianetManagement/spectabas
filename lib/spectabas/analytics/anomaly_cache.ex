defmodule Spectabas.Analytics.AnomalyCache do
  @moduledoc """
  Persists the result of `AnomalyDetector.detect/2` per site so the Insights
  page renders instantly without re-running 10+ ClickHouse comparison queries
  on every mount.

  Refreshed nightly by `Spectabas.Workers.DailyAnomalyDetection` and on demand
  via the Insights page Refresh button.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Spectabas.Repo

  schema "anomaly_cache" do
    field :site_id, :integer
    # Stored as a map: `%{"items" => [<anomaly>, ...]}`. JSONB doesn't preserve
    # atom keys, so all anomaly fields come back as string-keyed when read.
    field :anomalies, :map, default: %{}
    field :generated_at, :utc_datetime

    timestamps()
  end

  @doc "Latest cached entry for a site, or nil."
  def get(site_id) do
    Repo.one(from(c in __MODULE__, where: c.site_id == ^site_id))
  end

  @doc """
  Upsert the cache for a site. `anomalies` is the raw list of anomaly maps
  returned by `AnomalyDetector.detect/2` — this function wraps it under
  `%{"items" => …}` and serializes atoms to strings so JSONB roundtrips
  cleanly.
  """
  def put(site_id, anomalies) when is_list(anomalies) do
    serialized = %{"items" => Enum.map(anomalies, &serialize/1)}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get(site_id) do
      nil ->
        %__MODULE__{site_id: site_id}
        |> change(%{anomalies: serialized, generated_at: now})
        |> Repo.insert()

      existing ->
        existing
        |> change(%{anomalies: serialized, generated_at: now})
        |> Repo.update()
    end
  end

  @doc """
  Pull the items list out of a cached row and convert string keys back to
  atom keys + atom severities so it matches the shape `AnomalyDetector.detect`
  produces. Use this in the LiveView so the existing renderer works unchanged.
  """
  def items(%__MODULE__{anomalies: %{"items" => items}}) when is_list(items) do
    Enum.map(items, &deserialize/1)
  end

  def items(_), do: []

  # ---- (de)serialize helpers ----

  defp serialize(anomaly) when is_map(anomaly) do
    Map.new(anomaly, fn {k, v} -> {to_string(k), serialize_value(v)} end)
  end

  defp serialize_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: to_string(v)

  defp serialize_value(v), do: v

  @severity_atoms %{
    "high" => :high,
    "medium" => :medium,
    "low" => :low,
    "info" => :info
  }

  defp deserialize(item) when is_map(item) do
    %{
      severity: Map.get(@severity_atoms, item["severity"], :info),
      severity_rank: item["severity_rank"] || 4,
      category: item["category"] || "general",
      metric: item["metric"],
      current: item["current"],
      previous: item["previous"],
      change_pct: item["change_pct"],
      message: item["message"] || "",
      action: item["action"] || ""
    }
  end
end
