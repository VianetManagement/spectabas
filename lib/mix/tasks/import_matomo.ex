defmodule Mix.Tasks.ImportMatomo do
  @moduledoc """
  Import historical Matomo data into Spectabas ClickHouse events.

  Usage:
    mix import_matomo --site-id 4 --matomo-url https://a.roommates.com --matomo-site 2 --token TOKEN --from 2025-04-01 --to 2026-03-27

  To check imported count:
    mix import_matomo --site-id 4 --action status

  To roll back all imported data:
    mix import_matomo --site-id 4 --action rollback
  """

  use Mix.Task
  require Logger

  @shortdoc "Import historical data from Matomo API"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          site_id: :integer,
          matomo_url: :string,
          matomo_site: :integer,
          token: :string,
          from: :string,
          to: :string,
          action: :string
        ]
      )

    site_id = opts[:site_id] || raise "Missing --site-id"

    case opts[:action] do
      "status" ->
        count = Spectabas.Imports.Matomo.imported_count(site_id)
        Logger.info("[ImportMatomo] #{count} imported events for site #{site_id}")

      "rollback" ->
        case Spectabas.Imports.Matomo.rollback(site_id) do
          {:ok, count} -> Logger.info("[ImportMatomo] Rolled back #{count} events")
          {:error, reason} -> Logger.error("[ImportMatomo] Rollback failed: #{inspect(reason)}")
        end

      _ ->
        matomo_url = opts[:matomo_url] || raise "Missing --matomo-url"
        matomo_site = opts[:matomo_site] || raise "Missing --matomo-site"
        token = opts[:token] || raise "Missing --token"
        from = Date.from_iso8601!(opts[:from] || raise("Missing --from"))
        to = Date.from_iso8601!(opts[:to] || raise("Missing --to"))

        {:ok, total, days} =
          Spectabas.Imports.Matomo.import_range(
            site_id,
            matomo_url,
            matomo_site,
            token,
            from,
            to
          )

        Logger.info("[ImportMatomo] Done! #{total} events across #{days} days")
    end
  end
end
