defmodule Spectabas.GeoIP do
  @moduledoc """
  Manages GeoIP database loading via Geolix.
  Loads DB-IP (primary geo/ASN) and MaxMind GeoLite2 (timezone).
  Resolves database paths at runtime via :code.priv_dir.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    priv_dir = :code.priv_dir(:spectabas) |> to_string()

    databases = [
      %{
        id: :city,
        adapter: Geolix.Adapter.MMDB2,
        source: Path.join([priv_dir, "geoip", "dbip-city-lite.mmdb"])
      },
      %{
        id: :asn,
        adapter: Geolix.Adapter.MMDB2,
        source: Path.join([priv_dir, "geoip", "dbip-asn-lite.mmdb"])
      },
      %{
        id: :maxmind_city,
        adapter: Geolix.Adapter.MMDB2,
        source: Path.join([priv_dir, "geoip", "GeoLite2-City.mmdb"])
      }
    ]

    Enum.each(databases, fn db ->
      if File.exists?(db.source) do
        Geolix.load_database(db)
        Logger.info("[GeoIP] Loaded #{db.id} from #{db.source}")
      else
        Logger.info("[GeoIP] Not found (optional): #{db.source}")
      end
    end)

    {:ok, %{}}
  end
end
