defmodule Spectabas.Workers.SEOPageAudit do
  @moduledoc """
  Oban worker for per-page SEO audits. Args:

      %{"site_id" => integer, "url" => string, "trigger" => "on_demand"|"scheduled"|"backfill"}

  Pulls the URL through `Spectabas.SEO.HeadlessClient` (Playwright
  sidecar), parses + scores via `Spectabas.SEO.parse_and_score/3`,
  persists the row via `Spectabas.SEO.persist/1`. Logs start +
  elapsed_ms regardless of outcome.

  `on_demand` triggers do not count against the site's weekly crawl
  budget (`sites.seo_crawl_budget`). The budget is enforced at
  enqueue-time by `Spectabas.SEO.budget_remaining/2`; the worker itself
  doesn't recheck — once enqueued, it runs.

  Timeout: 60s. The headless fetch caps at 35s internally; the
  remainder is parsing + DB write + headroom for sidecar cold starts.
  """
  use Oban.Worker, queue: :default, max_attempts: 2

  require Logger
  alias Spectabas.SEO

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"site_id" => site_id, "url" => url} = args
      }) do
    trigger = Map.get(args, "trigger", "scheduled")
    started = System.monotonic_time(:millisecond)

    Logger.notice("[SEOPageAudit] site=#{site_id} trigger=#{trigger} url=#{url}")

    site = Spectabas.Sites.get_site!(site_id)

    fetch_opts = [user_agent: site.seo_user_agent]

    fetch_result =
      case SEO.HeadlessClient.fetch(url, fetch_opts) do
        {:ok, result} ->
          Map.put(result, :trigger, trigger)

        {:error, reason, meta} ->
          Map.merge(meta, %{error: reason, trigger: trigger})
      end

    attrs = SEO.parse_and_score(site_id, url, fetch_result)
    {:ok, _audit} = SEO.persist(attrs)

    elapsed = System.monotonic_time(:millisecond) - started

    Logger.notice(
      "[SEOPageAudit] site=#{site_id} url=#{url} score=#{attrs[:score] || "—"} elapsed_ms=#{elapsed}"
    )

    :ok
  end
end
