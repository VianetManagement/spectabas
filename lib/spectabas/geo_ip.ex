defmodule Spectabas.GeoIP do
  @moduledoc """
  Manages GeoIP database loading via Geolix.
  Resolves database paths at runtime via :code.priv_dir so it works
  in both dev and releases.
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
      }
    ]

    Enum.each(databases, fn db ->
      if File.exists?(db.source) do
        Geolix.load_database(db)
        Logger.info("[GeoIP] Loaded #{db.id} from #{db.source}")
      else
        Logger.warning("[GeoIP] Database not found: #{db.source}")
      end
    end)

    {:ok, %{}}
  end
end
