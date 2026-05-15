defmodule Spectabas.SEO.PageAudit do
  @moduledoc """
  Schema for a single page-audit row. One row per successful crawl
  (or failed crawl — `status_code` + `error` capture failures). Per
  (site_id, url) we cap retention at 12 rows via DELETE-on-insert in
  `Spectabas.SEO.persist/1` — enough history for ~3 months at weekly
  cadence and the title-change Insights from Phase 4.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "page_audits" do
    belongs_to :site, Spectabas.Sites.Site

    field :url, :string
    field :captured_at, :utc_datetime_usec
    field :trigger, :string, default: "scheduled"

    field :status_code, :integer
    field :final_url, :string
    field :response_time_ms, :integer
    field :content_hash, :string

    field :title, :string
    field :meta_description, :string
    field :h1, :string
    field :h1_count, :integer
    field :canonical, :string
    field :og_title, :string
    field :og_description, :string
    field :og_image, :string
    field :schema_types, {:array, :string}, default: []
    field :meta_robots, :string

    field :word_count, :integer
    field :internal_link_count, :integer
    field :external_link_count, :integer
    field :image_count, :integer
    field :image_alt_count, :integer

    field :score, :integer
    field :issues, :map, default: %{}
    field :error, :string

    # v6.10.52: richer audit payload — perf timing, heading tree,
    # viewport, twitter card, lang, https, etc. See moduledoc.
    field :extras, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(
    site_id url captured_at trigger
    status_code final_url response_time_ms content_hash
    title meta_description h1 h1_count canonical
    og_title og_description og_image schema_types meta_robots
    word_count internal_link_count external_link_count image_count image_alt_count
    score issues error extras
  )a

  def changeset(audit, attrs) do
    audit
    |> cast(attrs, @cast_fields)
    |> validate_required([:site_id, :url, :captured_at, :trigger])
    |> validate_inclusion(:trigger, ~w(scheduled on_demand backfill))
  end
end
