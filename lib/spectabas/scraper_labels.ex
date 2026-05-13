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

  # ---------------- Signal correlation report (Stage 1) ----------------

  @doc """
  Analyze accumulated labels for a site to surface where the hand-picked
  ScraperDetector weights agree or disagree with human judgment. Reads
  only **high-confidence** labels (default `source_weight >= 0.7`) so we
  don't train ourselves to match the auto-fired flags we're trying to
  improve.

  Returns:

  - `n_scraper` / `n_not_scraper` — sample sizes after the weight filter
  - `counts_by_source` — `{label, source, count}` for the full label history
  - `signal_stats` — list of per-signal stats. For each detector signal:
    - `scraper_count` / `scraper_pct`: how often the signal fired on rows
      where the human said scraper
    - `not_scraper_count` / `not_scraper_pct`: same for whitelist/unflag
    - `ratio`: `scraper_pct / not_scraper_pct` (`:infinity` when the
      not-scraper count is 0)
    - `current_weight`: the hand-picked weight from
      `ScraperDetector.default_weights/0`
    - `verdict`: heuristic — `:too_few_labels` / `:underweighted` /
      `:overweighted` / `:weak_signal` / `:ok`
  - `false_positives` — labels where current rules said "certain"
    (score ≥ 85) but a human disagreed and whitelisted/unflagged. These
    are the rows most worth eyeballing.
  - `false_negatives` — labels where current rules were below "watching"
    (score < 40) but a human still marked scraper.

  The verdict is heuristic, not a model. Use it to spot patterns and
  guide manual weight tweaks. Logistic-regression fitting is a separate
  follow-up (see `docs/scraper-labels.md`).
  """
  def signal_correlation_report(site_id, opts \\ []) do
    min_weight = Keyword.get(opts, :min_weight, Decimal.new("0.7"))
    fp_threshold = Keyword.get(opts, :fp_score_threshold, 85)
    fn_threshold = Keyword.get(opts, :fn_score_threshold, 40)
    limit = Keyword.get(opts, :limit, 50)

    high_conf =
      from(l in ScraperLabels,
        where: l.site_id == ^site_id and l.source_weight >= ^min_weight,
        select: %{label: l.label, signals: l.signals}
      )
      |> Repo.all()

    scrapers = Enum.filter(high_conf, &(&1.label == "scraper"))
    not_scrapers = Enum.filter(high_conf, &(&1.label == "not_scraper"))

    n_s = length(scrapers)
    n_ns = length(not_scrapers)

    weights = Spectabas.Analytics.ScraperDetector.default_weights()

    signal_stats =
      weights
      |> Map.keys()
      |> Enum.map(fn signal_atom ->
        signal_name = Atom.to_string(signal_atom)
        s_count = count_with_signal(scrapers, signal_name)
        ns_count = count_with_signal(not_scrapers, signal_name)

        s_pct = pct(s_count, n_s)
        ns_pct = pct(ns_count, n_ns)
        ratio = compute_ratio(s_pct, ns_pct)
        weight = Map.get(weights, signal_atom, 0)

        %{
          signal: signal_name,
          scraper_count: s_count,
          scraper_pct: s_pct,
          not_scraper_count: ns_count,
          not_scraper_pct: ns_pct,
          ratio: ratio,
          current_weight: weight,
          verdict: verdict_for(s_count, ns_count, ratio, weight)
        }
      end)
      |> Enum.sort_by(&sort_key/1)

    false_positives =
      from(l in ScraperLabels,
        where:
          l.site_id == ^site_id and
            l.label == "not_scraper" and
            l.source_weight >= ^min_weight and
            l.score >= ^fp_threshold,
        order_by: [desc: l.labeled_at],
        limit: ^limit
      )
      |> Repo.all()

    false_negatives =
      from(l in ScraperLabels,
        where:
          l.site_id == ^site_id and
            l.label == "scraper" and
            l.source_weight >= ^min_weight and
            l.score < ^fn_threshold,
        order_by: [desc: l.labeled_at],
        limit: ^limit
      )
      |> Repo.all()

    %{
      n_scraper: n_s,
      n_not_scraper: n_ns,
      counts_by_source: counts_by_source(site_id),
      signal_stats: signal_stats,
      false_positives: false_positives,
      false_negatives: false_negatives
    }
  end

  defp count_with_signal(rows, signal_name) do
    Enum.count(rows, fn row ->
      Map.get(row.signals || %{}, signal_name) == true
    end)
  end

  defp pct(_count, 0), do: 0.0
  defp pct(count, total), do: Float.round(count / total * 100, 1)

  defp compute_ratio(+0.0, +0.0), do: 0.0
  defp compute_ratio(_s_pct, +0.0), do: :infinity
  defp compute_ratio(s_pct, ns_pct), do: Float.round(s_pct / ns_pct, 2)

  # Heuristics surface ONLY clear patterns. Anything ambiguous → :ok so
  # nobody mistakes the verdict for ground truth.
  defp verdict_for(s_count, ns_count, _ratio, _weight)
       when s_count + ns_count < 5,
       do: :too_few_labels

  defp verdict_for(_s, _ns, ratio, weight)
       when (ratio == :infinity or (is_number(ratio) and ratio > 4)) and weight < 15,
       do: :underweighted

  defp verdict_for(_s, _ns, ratio, weight)
       when is_number(ratio) and ratio < 0.5 and weight >= 10,
       do: :overweighted

  defp verdict_for(_s, _ns, ratio, weight)
       when is_number(ratio) and ratio >= 0.66 and ratio <= 1.5 and weight >= 10,
       do: :weak_signal

  defp verdict_for(_, _, _, _), do: :ok

  # Sort key: non-:ok verdicts first, then by magnitude of disagreement
  # (largest |log(ratio)| first within each verdict band).
  defp sort_key(%{verdict: :ok}), do: {1, 0.0}
  defp sort_key(%{ratio: :infinity}), do: {0, -1000.0}

  defp sort_key(%{ratio: ratio}) when is_number(ratio) and ratio > 0,
    do: {0, -abs(:math.log(ratio))}

  defp sort_key(_), do: {0, 0.0}
end
