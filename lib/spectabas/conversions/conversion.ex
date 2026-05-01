defmodule Spectabas.Conversions.Conversion do
  @moduledoc """
  One row per detected conversion. The `dedup_key` enforces idempotency so
  detector retries can never double-count.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @upload_states ~w(
    pending skipped_no_click skipped_quality uploading
    uploaded_google uploaded_microsoft uploaded_both failed
  )

  @detection_sources ~w(stripe pageview click_element custom_event manual)

  schema "conversions" do
    field :site_id, :id
    field :conversion_action_id, :id
    field :visitor_id, Ecto.UUID
    field :email, :string
    field :click_id, :string
    field :click_id_type, :string
    field :occurred_at, :utc_datetime
    field :value, :decimal, default: Decimal.new(0)
    field :currency, :string
    field :detection_source, :string
    field :source_reference, :string
    field :dedup_key, :string
    field :upload_state, :string, default: "pending"
    field :uploaded_at, :utc_datetime
    field :upload_error, :string
    field :google_match_status, :string
    field :microsoft_match_status, :string
    field :scraper_score_at_detect, :integer

    timestamps()
  end

  def upload_states, do: @upload_states
  def detection_sources, do: @detection_sources

  def changeset(conversion, attrs) do
    conversion
    |> cast(attrs, [
      :site_id,
      :conversion_action_id,
      :visitor_id,
      :email,
      :click_id,
      :click_id_type,
      :occurred_at,
      :value,
      :currency,
      :detection_source,
      :source_reference,
      :dedup_key,
      :upload_state,
      :uploaded_at,
      :upload_error,
      :google_match_status,
      :microsoft_match_status,
      :scraper_score_at_detect
    ])
    |> validate_required([
      :site_id,
      :conversion_action_id,
      :occurred_at,
      :detection_source,
      :dedup_key,
      :upload_state
    ])
    |> validate_inclusion(:detection_source, @detection_sources)
    |> validate_inclusion(:upload_state, @upload_states)
    |> unique_constraint([:site_id, :conversion_action_id, :dedup_key],
      name: :conversions_dedup_idx
    )
  end
end
