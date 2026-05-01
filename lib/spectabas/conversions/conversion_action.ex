defmodule Spectabas.Conversions.ConversionAction do
  @moduledoc """
  Per-site config that maps a Spectabas-detected event to a Google Ads /
  Microsoft Ads conversion action. See `docs/conversions.md`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(signup listing purchase custom)
  @detection_types ~w(url_pattern click_element stripe_payment custom_event)
  @value_strategies ~w(count_only from_payment fixed)
  @attribution_models ~w(first_click last_click)

  schema "conversion_actions" do
    field :site_id, :id
    field :name, :string
    field :kind, :string
    field :detection_type, :string
    field :detection_config, :map, default: %{}
    field :value_strategy, :string, default: "count_only"
    field :fixed_value, :decimal
    field :attribution_window_days, :integer, default: 90
    field :attribution_model, :string, default: "first_click"
    field :google_conversion_action_id, :string
    field :google_account_timezone, :string
    field :microsoft_conversion_name, :string
    field :active, :boolean, default: true
    field :max_scraper_score, :integer, default: 40

    timestamps()
  end

  def kinds, do: @kinds
  def detection_types, do: @detection_types
  def value_strategies, do: @value_strategies
  def attribution_models, do: @attribution_models

  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :site_id,
      :name,
      :kind,
      :detection_type,
      :detection_config,
      :value_strategy,
      :fixed_value,
      :attribution_window_days,
      :attribution_model,
      :google_conversion_action_id,
      :google_account_timezone,
      :microsoft_conversion_name,
      :active,
      :max_scraper_score
    ])
    |> validate_required([:site_id, :name, :kind, :detection_type])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:detection_type, @detection_types)
    |> validate_inclusion(:value_strategy, @value_strategies)
    |> validate_inclusion(:attribution_model, @attribution_models)
    |> validate_number(:attribution_window_days, greater_than: 0, less_than_or_equal_to: 90)
    |> validate_number(:max_scraper_score,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_detection_config()
  end

  defp validate_detection_config(changeset) do
    type = get_field(changeset, :detection_type)
    config = get_field(changeset, :detection_config) || %{}

    case type do
      "url_pattern" ->
        if is_binary(config["url_pattern"]) and config["url_pattern"] != "" do
          changeset
        else
          add_error(
            changeset,
            :detection_config,
            "url_pattern required for url_pattern detection"
          )
        end

      "click_element" ->
        if is_binary(config["selector"]) and config["selector"] != "" do
          changeset
        else
          add_error(changeset, :detection_config, "selector required for click_element detection")
        end

      "custom_event" ->
        if is_binary(config["event_name"]) and config["event_name"] != "" do
          changeset
        else
          add_error(
            changeset,
            :detection_config,
            "event_name required for custom_event detection"
          )
        end

      "stripe_payment" ->
        # No additional config required; relies on existing Stripe integration.
        changeset

      _ ->
        changeset
    end
  end
end
