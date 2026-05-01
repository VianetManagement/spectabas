defmodule Spectabas.Conversions do
  @moduledoc """
  Context module for server-side conversion tracking. Detectors call
  `record/1` after resolving a click; the upload worker pushes pending rows
  to Google Data Manager API and Microsoft Ads.

  See `docs/conversions.md` for the full design.
  """

  import Ecto.Query
  require Logger

  alias Spectabas.Repo
  alias Spectabas.Conversions.{Conversion, ConversionAction, ClickResolver}
  alias Spectabas.Sites.Site

  # ---- Conversion actions (per-site config) ----

  def list_actions(%Site{} = site) do
    Repo.all(
      from(a in ConversionAction,
        where: a.site_id == ^site.id,
        order_by: [asc: a.kind, asc: a.name]
      )
    )
  end

  def list_active_actions(%Site{} = site) do
    Repo.all(
      from(a in ConversionAction,
        where: a.site_id == ^site.id and a.active == true,
        order_by: [asc: a.kind]
      )
    )
  end

  def get_action!(%Site{} = site, id) do
    Repo.get_by!(ConversionAction, id: id, site_id: site.id)
  end

  def create_action(%Site{} = site, attrs) do
    %ConversionAction{}
    |> ConversionAction.changeset(Map.put(attrs, "site_id", site.id))
    |> Repo.insert()
  end

  def update_action(%ConversionAction{} = action, attrs) do
    action
    |> ConversionAction.changeset(attrs)
    |> Repo.update()
  end

  def delete_action(%ConversionAction{} = action) do
    Repo.delete(action)
  end

  # ---- Recording conversions ----

  @doc """
  Idempotent — if a row with the same `dedup_key` exists for this
  `(site_id, conversion_action_id)`, returns it unchanged. Otherwise
  resolves the click identifier and inserts.

  `attrs` keys: visitor_id, email, occurred_at, value, currency,
  detection_source, source_reference, dedup_key, scraper_score.
  """
  def record(%Site{} = site, %ConversionAction{} = action, attrs) do
    dedup_key = attrs[:dedup_key] || attrs["dedup_key"]

    case fetch_existing(site.id, action.id, dedup_key) do
      %Conversion{} = existing ->
        {:ok, existing}

      nil ->
        do_record(site, action, attrs)
    end
  end

  defp fetch_existing(_site_id, _action_id, nil), do: nil

  defp fetch_existing(site_id, action_id, dedup_key) do
    Repo.one(
      from(c in Conversion,
        where:
          c.site_id == ^site_id and c.conversion_action_id == ^action_id and
            c.dedup_key == ^dedup_key
      )
    )
  end

  defp do_record(site, action, attrs) do
    visitor_id = attrs[:visitor_id] || attrs["visitor_id"]
    email = attrs[:email] || attrs["email"]
    occurred_at = attrs[:occurred_at] || attrs["occurred_at"] || DateTime.utc_now()
    occurred_at = DateTime.truncate(occurred_at, :second)
    scraper_score = attrs[:scraper_score] || attrs["scraper_score"]

    {click_id, click_type} = resolve_click(site, action, visitor_id, email, occurred_at)

    upload_state =
      cond do
        is_nil(click_id) -> "skipped_no_click"
        quality_block?(action, scraper_score) -> "skipped_quality"
        true -> "pending"
      end

    insert_attrs = %{
      site_id: site.id,
      conversion_action_id: action.id,
      visitor_id: visitor_id,
      email: email,
      click_id: click_id,
      click_id_type: click_type,
      occurred_at: occurred_at,
      value: resolve_value(action, attrs),
      currency: attrs[:currency] || attrs["currency"],
      detection_source: attrs[:detection_source] || attrs["detection_source"],
      source_reference: attrs[:source_reference] || attrs["source_reference"],
      dedup_key: attrs[:dedup_key] || attrs["dedup_key"],
      upload_state: upload_state,
      scraper_score_at_detect: scraper_score
    }

    %Conversion{}
    |> Conversion.changeset(insert_attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:site_id, :conversion_action_id, :dedup_key]
    )
    |> case do
      {:ok, %Conversion{id: nil}} ->
        # Conflict short-circuited; fetch the row that won.
        {:ok, fetch_existing(site.id, action.id, insert_attrs.dedup_key)}

      result ->
        result
    end
  end

  defp resolve_click(site, action, visitor_id, email, occurred_at) do
    opts = [
      window_days: action.attribution_window_days || 90,
      attribution_model: action.attribution_model || "first_click"
    ]

    cond do
      is_binary(visitor_id) and visitor_id != "" ->
        case ClickResolver.resolve(site, visitor_id, occurred_at, opts) do
          {nil, nil} when is_binary(email) and email != "" ->
            ClickResolver.resolve_by_email(site, email, occurred_at, opts)

          result ->
            result
        end

      is_binary(email) and email != "" ->
        ClickResolver.resolve_by_email(site, email, occurred_at, opts)

      true ->
        {nil, nil}
    end
  end

  defp quality_block?(%ConversionAction{max_scraper_score: max}, score)
       when is_integer(max) and max > 0 and is_integer(score),
       do: score >= max

  defp quality_block?(_, _), do: false

  defp resolve_value(%ConversionAction{value_strategy: "from_payment"}, attrs) do
    decimal(attrs[:value] || attrs["value"] || 0)
  end

  defp resolve_value(%ConversionAction{value_strategy: "fixed", fixed_value: v}, _attrs)
       when not is_nil(v),
       do: v

  defp resolve_value(_, _), do: Decimal.new(0)

  defp decimal(%Decimal{} = d), do: d
  defp decimal(n) when is_integer(n), do: Decimal.new(n)
  defp decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> Decimal.new(0)
    end
  end

  defp decimal(_), do: Decimal.new(0)

  # ---- Upload queue ----

  @doc "Pending conversions for a site, oldest first, capped."
  def list_pending(site_id, limit \\ 1000) do
    Repo.all(
      from(c in Conversion,
        where: c.site_id == ^site_id and c.upload_state == "pending",
        order_by: [asc: c.occurred_at],
        limit: ^limit
      )
    )
  end

  def mark_uploaded(conversions, platform) when platform in [:google, :microsoft, :both] do
    ids = Enum.map(conversions, & &1.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    state =
      case platform do
        :google -> "uploaded_google"
        :microsoft -> "uploaded_microsoft"
        :both -> "uploaded_both"
      end

    Repo.update_all(
      from(c in Conversion, where: c.id in ^ids),
      set: [upload_state: state, uploaded_at: now, updated_at: now, upload_error: nil]
    )
  end

  def mark_failed(conversions, error) when is_list(conversions) do
    ids = Enum.map(conversions, & &1.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(c in Conversion, where: c.id in ^ids),
      set: [
        upload_state: "failed",
        upload_error: String.slice(to_string(error), 0, 1000),
        updated_at: now
      ]
    )
  end

  # ---- Stats / health ----

  def site_summary(site_id, since) do
    Repo.all(
      from(c in Conversion,
        where: c.site_id == ^site_id and c.occurred_at >= ^since,
        group_by: c.upload_state,
        select: {c.upload_state, count(c.id)}
      )
    )
    |> Map.new()
  end
end
