defmodule Spectabas.ASNManagement do
  require Logger
  import Ecto.Query

  alias Spectabas.Repo

  defmodule Override do
    use Ecto.Schema
    import Ecto.Changeset

    schema "asn_overrides" do
      field :asn_number, :integer
      field :asn_org, :string, default: ""
      field :classification, :string
      field :source, :string, default: "auto"
      field :reason, :string
      field :auto_evidence, :map
      field :active, :boolean, default: true
      field :backfill_submitted, :boolean, default: false

      timestamps(type: :utc_datetime)
    end

    @valid_classifications ~w(datacenter vpn privacy_relay residential)
    @valid_sources ~w(auto manual file)

    def changeset(override, attrs) do
      override
      |> cast(attrs, [
        :asn_number,
        :asn_org,
        :classification,
        :source,
        :reason,
        :auto_evidence,
        :active,
        :backfill_submitted
      ])
      |> validate_required([:asn_number, :classification, :source])
      |> validate_inclusion(:classification, @valid_classifications)
      |> validate_inclusion(:source, @valid_sources)
    end
  end

  def list_overrides(opts \\ []) do
    query = from(o in Override, order_by: [desc: o.inserted_at])

    query =
      case Keyword.get(opts, :active) do
        true -> where(query, [o], o.active == true)
        false -> where(query, [o], o.active == false)
        _ -> query
      end

    query =
      case Keyword.get(opts, :classification) do
        nil -> query
        c -> where(query, [o], o.classification == ^c)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        n -> limit(query, ^n)
      end

    Repo.all(query)
  end

  def recent_changes(limit \\ 50) do
    from(o in Override, order_by: [desc: o.inserted_at], limit: ^limit)
    |> Repo.all()
  end

  def add_override(attrs) do
    %Override{}
    |> Override.changeset(attrs)
    |> Repo.insert()
  end

  def deactivate_override(id) do
    case Repo.get(Override, id) do
      nil -> {:error, :not_found}
      override -> override |> Override.changeset(%{active: false}) |> Repo.update()
    end
  end

  def mark_backfilled(id) do
    case Repo.get(Override, id) do
      nil -> {:error, :not_found}
      override -> override |> Override.changeset(%{backfill_submitted: true}) |> Repo.update()
    end
  end

  def active_datacenter_asns do
    from(o in Override,
      where: o.active == true and o.classification == "datacenter",
      select: o.asn_number
    )
    |> Repo.all()
  end

  def already_tracked?(asn_number, classification) do
    from(o in Override,
      where:
        o.asn_number == ^asn_number and o.classification == ^classification and o.active == true
    )
    |> Repo.exists?()
  end
end
