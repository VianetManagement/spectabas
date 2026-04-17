defmodule Spectabas.Workers.ScraperWebhookScan do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias Spectabas.{Analytics, Repo, Sites}
  alias Spectabas.Analytics.ScraperDetector
  alias Spectabas.Visitors.Visitor
  alias Spectabas.Webhooks.ScraperWebhook

  import Ecto.Query

  @impl Oban.Worker
  def perform(_job) do
    sites = sites_with_webhooks()

    if sites == [] do
      :ok
    else
      Enum.each(sites, &scan_site/1)
      :ok
    end
  end

  defp sites_with_webhooks do
    Repo.all(
      from(s in Sites.Site,
        where:
          s.scraper_webhook_enabled == true and
            not is_nil(s.scraper_webhook_url) and s.scraper_webhook_url != "" and
            not is_nil(s.scraper_webhook_secret) and s.scraper_webhook_secret != ""
      )
    )
  end

  defp scan_site(site) do
    case Analytics.scraper_candidates_system(site,
           hours: 1,
           min_score: ScraperDetector.score_watching()
         ) do
      {:ok, candidates} ->
        Logger.notice(
          "[ScraperWebhookScan] site=#{site.id} found #{length(candidates)} candidates"
        )

        Enum.each(candidates, fn row ->
          process_candidate(site, row)
        end)

      {:error, reason} ->
        Logger.warning("[ScraperWebhookScan] site=#{site.id} query failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.warning("[ScraperWebhookScan] site=#{site.id} error: #{inspect(e)}")
  end

  defp process_candidate(site, row) do
    visitor_id = row["visitor_id"]
    score = row["score"]
    signals = row["signals"]

    # Look up the Postgres visitor record for known_ips, external_id, user_id
    visitor = Repo.one(from(v in Visitor, where: v.id == ^visitor_id, limit: 1))

    if visitor do
      prev = visitor.scraper_webhook_score || 0
      prev_tier = score_tier(prev)
      curr_tier = score_tier(score)

      cond do
        # Never sent — first flag
        is_nil(visitor.scraper_webhook_sent_at) ->
          send_and_record(site, visitor, score, signals, row)

        # Score escalated to a higher tier (watching → suspicious → certain)
        curr_tier > prev_tier ->
          send_and_record(site, visitor, score, signals, row)

        # Same tier — skip
        true ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning(
        "[ScraperWebhookScan] Failed processing visitor #{row["visitor_id"]}: #{inspect(e)}"
      )
  end

  defp send_and_record(site, visitor, score, signals, row) do
    score_result = %{score: score, signals: signals}
    pageviews = row["session_pageviews"] || 0

    case ScraperWebhook.send_flag(site, visitor, score_result, pageviews) do
      {:ok, _body} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        visitor
        |> Visitor.changeset(%{scraper_webhook_sent_at: now, scraper_webhook_score: score})
        |> Repo.update()

      {:error, _reason} ->
        :ok
    end
  end

  # Maps score to a numeric tier for escalation comparison:
  # 0 = watching (40-69), 1 = suspicious/tarpit (70-84), 2 = certain/active (85+)
  defp score_tier(score) when score >= 85, do: 2
  defp score_tier(score) when score >= 70, do: 1
  defp score_tier(_), do: 0
end
