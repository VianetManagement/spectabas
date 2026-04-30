defmodule Spectabas.ScraperLabels do
  @moduledoc """
  Append-only log of human and machine judgments about whether a visitor is a
  scraper. Feeds future supervised training of the scraper-detection weights
  (logistic regression on the existing 15-signal vector). Storing labels does
  NOT change current detection behavior — it just captures decisions and the
  signal context at the moment they were made.

  See `dev/scraper_labels.md` for the full design rationale and label policy.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Spectabas.Repo
  alias Spectabas.ScraperLabels
  require Logger

  @primary_key {:id, :id, autogenerate: true}

  schema "scraper_labels" do
    field :site_id, :id
    field :visitor_id, Ecto.UUID
    field :label, :string
    field :source, :string
    field :source_weight, :decimal
    field :score, :integer
    field :tier, :string
    field :signals, :map, default: %{}
    field :email, :string
    field :user_id, :id
    field :notes, :string
    field :labeled_at, :utc_datetime

    timestamps(updated_at: false)
  end

  @valid_labels ~w(scraper not_scraper)

  @valid_sources ~w(
    manual_flag manual_whitelist manual_unflag manual_unwhitelist
    api_whitelist api_unwhitelist
    webhook_auto_flag webhook_downgrade
    goal_conversion ecommerce_purchase
  )

  # Confidence weights, used at training time. See dev/scraper_labels.md.
  # Human clicks are 1.0; auto-fired flags are downweighted because they're
  # circular (the rules we're trying to learn produced them). Negatives from
  # actual conversions/purchases are strong signal.
  @source_weights %{
    "manual_flag" => 1.0,
    "manual_whitelist" => 1.0,
    "manual_unflag" => 0.5,
    "manual_unwhitelist" => 0.4,
    "api_whitelist" => 1.0,
    "api_unwhitelist" => 0.4,
    "webhook_auto_flag" => 0.3,
    "webhook_downgrade" => 0.3,
    "goal_conversion" => 0.7,
    "ecommerce_purchase" => 0.9
  }

  @doc """
  Record a label. Best-effort: any failure is logged and swallowed so the
  caller's main action is never blocked. Returns `:ok` regardless of insert
  success.
  """
  def record(attrs) when is_map(attrs) do
    try do
      attrs
      |> normalize_keys()
      |> normalize_signals()
      |> with_default_weight()
      |> with_default_labeled_at()
      |> insert!()

      :ok
    rescue
      e ->
        Logger.warning(
          "[ScraperLabels] insert failed: #{Exception.message(e)} attrs=#{inspect(attrs)}"
        )

        :ok
    end
  end

  defp insert!(attrs) do
    %ScraperLabels{}
    |> changeset(attrs)
    |> Repo.insert!()
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [
      :site_id,
      :visitor_id,
      :label,
      :source,
      :source_weight,
      :score,
      :tier,
      :signals,
      :email,
      :user_id,
      :notes,
      :labeled_at
    ])
    |> validate_required([:site_id, :label, :source, :source_weight, :labeled_at])
    |> validate_inclusion(:label, @valid_labels)
    |> validate_inclusion(:source, @valid_sources)
  end

  @doc "List labels for a site, newest first. Used by the future calibration UI."
  def list_for_site(site_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    from(l in ScraperLabels,
      where: l.site_id == ^site_id,
      order_by: [desc: l.labeled_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Counts of labels by source for a site (sanity / health check)."
  def counts_by_source(site_id) do
    from(l in ScraperLabels,
      where: l.site_id == ^site_id,
      group_by: [l.label, l.source],
      select: {l.label, l.source, count(l.id)}
    )
    |> Repo.all()
  end

  defp normalize_keys(attrs) do
    attrs
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
    end)
    |> Map.new()
  end

  defp with_default_weight(%{source: source} = attrs) when is_binary(source) do
    Map.put_new(attrs, :source_weight, Map.get(@source_weights, source, 0.5))
  end

  defp with_default_weight(attrs), do: attrs

  # Signals come in as a list of atoms or strings (current ScraperDetector
  # output). Convert to a map so we can query "labels where signal X was on"
  # without parsing JSON arrays.
  defp normalize_signals(%{signals: signals} = attrs) when is_list(signals) do
    Map.put(attrs, :signals, Map.new(signals, fn s -> {to_string(s), true} end))
  end

  defp normalize_signals(%{signals: signals} = attrs) when is_map(signals), do: attrs
  defp normalize_signals(attrs), do: Map.put_new(attrs, :signals, %{})

  defp with_default_labeled_at(attrs) do
    Map.put_new(attrs, :labeled_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc "Map source → confidence weight. Public so future training jobs can read it."
  def source_weights, do: @source_weights
end
