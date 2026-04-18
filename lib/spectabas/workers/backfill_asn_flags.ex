defmodule Spectabas.Workers.BackfillASNFlags do
  @moduledoc """
  One-shot backfill worker that applies `ip_is_datacenter`, `ip_is_vpn`, and
  `ip_is_tor` flags to existing `events` rows based on the current
  `Spectabas.IPEnricher.ASNBlocklist` ETS tables.

  Ran automatically once after the ASN-blocklist parser bug fix (the bug
  caused every existing event to have these flags = 0). Enqueue manually:

      Oban.insert(Spectabas.Workers.BackfillASNFlags.new(%{}))

  Strategy: one ALTER TABLE UPDATE per flag, with `ip_asn IN (…)` over the
  full blocklist. ClickHouse ALTER UPDATE is asynchronous by default but we
  use `mutations_sync = 2` to wait for completion so Oban doesn't retry.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger
  alias Spectabas.{ClickHouse, IPEnricher.ASNBlocklist}

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(600)

  @impl Oban.Worker
  def perform(_job) do
    Logger.notice("[BackfillASNFlags] starting")

    # Set all three flags back to 0 first, so de-listed ASNs don't keep stale
    # flags. Then re-flag anything currently in each list. This is idempotent.
    results = [
      reset_and_flag(:ip_is_datacenter, ASNBlocklist.all(:datacenter), "datacenter"),
      reset_and_flag(:ip_is_vpn, ASNBlocklist.all(:vpn), "vpn"),
      reset_and_flag(:ip_is_tor, ASNBlocklist.all(:tor), "tor")
    ]

    if Enum.all?(results, &(&1 == :ok)) do
      Logger.notice("[BackfillASNFlags] done")
      :ok
    else
      {:error, "one or more flag updates failed — see earlier logs"}
    end
  end

  defp reset_and_flag(_col, [], label) do
    Logger.warning("[BackfillASNFlags] #{label} list is empty — skipping")
    :ok
  end

  defp reset_and_flag(col, asns, label) do
    asn_list = Enum.join(asns, ", ")

    # Reset: set everything to 0 (where currently 1). Then set to 1 for ASNs
    # in the list. Two narrow updates are cheaper than one broad one.
    reset_sql =
      "ALTER TABLE events UPDATE #{col} = 0 WHERE #{col} = 1 SETTINGS mutations_sync = 2"

    flag_sql =
      "ALTER TABLE events UPDATE #{col} = 1 WHERE ip_asn IN (#{asn_list}) SETTINGS mutations_sync = 2"

    with :ok <- ClickHouse.execute(reset_sql),
         :ok <- ClickHouse.execute(flag_sql) do
      Logger.notice("[BackfillASNFlags] #{label}: flagged #{length(asns)} ASNs")
      :ok
    else
      {:error, reason} ->
        Logger.error("[BackfillASNFlags] #{label} failed: #{inspect(reason)}")
        :error
    end
  end
end
