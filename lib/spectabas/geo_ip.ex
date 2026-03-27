defmodule Spectabas.GeoIP do
  @moduledoc """
  Manages GeoIP database loading via Geolix.
  Only starts if mmdb files are present.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    databases = Application.get_env(:geolix, :databases, [])

    # Only load databases if files exist
    valid_databases =
      Enum.filter(databases, fn db ->
        source = db[:source]
        is_binary(source) && File.exists?(source)
      end)

    Enum.each(valid_databases, fn db ->
      Geolix.load_database(db)
    end)

    {:ok, %{}}
  end
end
